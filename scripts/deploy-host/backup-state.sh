#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/deploy-host/backup-state.sh
#
# Purpose:  Back up deploy-host operator-managed state (SSH keys,
#           .env, .aws/config, custom bin/ dirs) to the sandbox
#           deploy-host backups S3 bucket.
#
#           Mirrors scripts/migration/scripts/jumpbox/backup-state.sh
#           but targets deploy-host paths and its own dedicated bucket
#           (long-lived, unlike the ephemeral migration bucket).
#
#           IMPORTANT: /root/.aws/credentials and /home/ubuntu/.aws/credentials
#           are DELIBERATELY EXCLUDED. They contain the ZoningInfoAdmin
#           long-lived cross-account keys — high-value secrets we do
#           not want copied into S3. Instead, restore-state.sh writes
#           a stub file pointing the operator back to their Mac for
#           the real credentials. See restore-state.sh for details.
#
# Flow (five phases, mirrors the jumpbox backup):
#   1. Preconditions       (root, tools, AWS creds)
#   2. Enumerate paths     (skip & warn on missing)
#   3. Create tarball      (gzip, /tmp intermediate, ownership preserved)
#   4. Upload to S3        (timestamped archive + latest pointer)
#   5. Verify              (head-object on both S3 objects)
#
# Backed-up paths (all optional - skip & warn if missing):
#   /root/.ssh/            SSH keys, known_hosts, authorized_keys
#   /root/.env             Env vars for root shell (if operator uses)
#   /root/bin/             Custom root scripts (if operator uses)
#   /root/.aws/config      AWS CLI profile definitions (NOT credentials)
#   /home/ubuntu/.ssh/     SSH keys for ubuntu user
#   /home/ubuntu/.env      Env vars for ubuntu shell
#   /home/ubuntu/bin/      Custom ubuntu scripts
#   /home/ubuntu/.aws/config  AWS CLI profile definitions
#
# NOT backed up:
#   /root/.aws/credentials, /home/ubuntu/.aws/credentials
#     - Contain long-lived ZoningInfoAdmin cross-account keys
#     - Restore writes a stub file directing operator to their Mac
#   /etc/worxco/envs/*
#     - Regenerated on boot by scripts/deploy-host/refresh-env-config
#     - Pulls current values from SSM Parameter Store
#   Git repo (~/projects/...), FSx mounts, MariaDB
#     - Handled by deploy-host CFN or persistent storage
#
# S3 layout produced:
#   s3://$DEPLOY_HOST_BACKUPS_BUCKET/config/deploy-host-archive/deploy-host-<UTC>.tar.gz
#     └── timestamped durable copy; 90-day expiration via bucket lifecycle
#   s3://$DEPLOY_HOST_BACKUPS_BUCKET/config/deploy-host-latest.tar.gz
#     └── S3-side copy of the newest timestamped archive; never expires;
#         auto-restore source for new deploy-host instances
#
# Idempotent:  Yes - each invocation writes a new timestamped archive
#              and overwrites the latest pointer atomically.
#
# Environment variables (all optional, listed with defaults):
#   DEPLOY_HOST_BACKUPS_BUCKET  Bucket name  (sandbox-deploy-host-backups-kv-worxco)
#   S3_PREFIX                   Top-level prefix (config)
#   DRY_RUN                     yes = preview commands without executing
#
# Runs as:  root on deploy-host (needs read access to /root and privileged
#           /home/ubuntu subdirs)
# Host:     deploy-host (sandbox VPC)
# Called by:
#   - `make backup-deploy-host` (on-demand from Mac|DH via SSM send-command)
#   - EventBridge Scheduler nightly at 02:00 America/Chicago (via cf-deploy-host.yaml)
#   - `make destroy-deploy-host` (pre-destroy final backup)
#
# Created:  2026-07-15
# ============================================================

set -euo pipefail

# Source shared helpers. This script mirrors the migration scripts'
# structure, so we source the same _common.sh (which lives under the
# migration folder). If deploy-host is used without migration/, the
# operator can copy _common.sh under scripts/deploy-host/ or into
# /opt/deploy-host/scripts/ - the sourcing path below picks up either.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/_common.sh" ]; then
  # Standalone deployment or same-dir layout
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/_common.sh"
elif [ -f "$SCRIPT_DIR/../_common.sh" ]; then
  # SSM-uploaded layout: _ssm-run.sh places _common.sh one dir up
  # (at /opt/deploy-host/scripts/_common.sh) while this script lands
  # under scripts/deploy-host/. Same pattern as jumpbox scripts.
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../_common.sh"
elif [ -f "$SCRIPT_DIR/../../migration/scripts/_common.sh" ]; then
  # Repo layout fallback: script running from git checkout
  # (scripts/deploy-host/) can reach migration/scripts/_common.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../../migration/scripts/_common.sh"
else
  echo "ERROR: cannot find _common.sh (looked at same-dir, ../_common.sh, and ../../migration/scripts/)" >&2
  exit 1
fi

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
DEPLOY_HOST_BACKUPS_BUCKET="${DEPLOY_HOST_BACKUPS_BUCKET:-sandbox-deploy-host-backups-kv-worxco}"
S3_PREFIX="${S3_PREFIX:-config}"

# S3 object keys derived from the prefix
ARCHIVE_PREFIX="$S3_PREFIX/deploy-host-archive"
LATEST_KEY="$S3_PREFIX/deploy-host-latest.tar.gz"

# The set of paths we back up. Absolute paths; skip-and-warn if missing.
# Explicitly EXCLUDES .aws/credentials files (see header comment).
BACKUP_PATHS=(
  "/root/.ssh"
  "/root/.env"
  "/root/bin"
  "/root/.aws/config"
  "/home/ubuntu/.ssh"
  "/home/ubuntu/.env"
  "/home/ubuntu/bin"
  "/home/ubuntu/.aws/config"
)

# ============================================================
# Set up logging + on-exit S3 upload of THIS script's log
# ============================================================
log_init "backup-state-deploy-host"
trap 'log_upload_and_exit "$DEPLOY_HOST_BACKUPS_BUCKET"' EXIT

log_step "backup-state (deploy-host) - state → sandbox S3"
log_info "DEPLOY_HOST_BACKUPS_BUCKET = $DEPLOY_HOST_BACKUPS_BUCKET"
log_info "S3 destination:"
log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$ARCHIVE_PREFIX/  ← timestamped (90-day retention)"
log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$LATEST_KEY       ← latest pointer (never expires)"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes - commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 5: Preconditions
# ============================================================
log_step "Phase 1/5: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root - need read access to /root/.ssh and other privileged paths."
  log_error "Example: sudo -E ./backup-state.sh"
  exit 1
fi

require_env DEPLOY_HOST_BACKUPS_BUCKET

for tool in tar aws du stat; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    exit 1
  fi
done

if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  log_error "AWS credentials are not working. Check instance role attachment."
  exit 1
fi

log_ok "Preconditions satisfied"

# ============================================================
# Phase 2 of 5: Enumerate paths (skip & warn on missing)
# ============================================================
log_step "Phase 2/5: Enumerate paths to back up"

REL_PATHS=()
TOTAL_BYTES=0
for path in "${BACKUP_PATHS[@]}"; do
  if [ -e "$path" ]; then
    SIZE=$(du -sb "$path" 2>/dev/null | cut -f1)
    REL_PATHS+=("${path#/}")
    TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
    log_ok "  $path (${SIZE} bytes)"
  else
    log_warn "  $path - not found, skipping"
  fi
done

if [ ${#REL_PATHS[@]} -eq 0 ]; then
  log_error "No paths found to back up. Aborting."
  log_error "(All backup targets in BACKUP_PATHS[] were missing.)"
  exit 1
fi

log_info "Total: ${#REL_PATHS[@]} paths, ~$((TOTAL_BYTES / 1024)) KB (uncompressed)"

# ============================================================
# Phase 3 of 5: Create tarball
# ============================================================
log_step "Phase 3/5: Create tarball"

TIMESTAMP=$(date -u +%Y%m%d-%H%M%SZ)
ARCHIVE_NAME="deploy-host-${TIMESTAMP}.tar.gz"
LOCAL_ARCHIVE="/tmp/$ARCHIVE_NAME"

log_info "Building $LOCAL_ARCHIVE"

if is_dry_run; then
  log_info "[DRY_RUN] would run: tar -czf $LOCAL_ARCHIVE -C / ${REL_PATHS[*]}"
else
  # Include a manifest file inside the archive documenting what's in
  # it (paths, sizes, hostname, timestamp). Makes forensics easier
  # months later when the S3 archive is the only trail.
  MANIFEST=$(mktemp)
  {
    echo "# deploy-host state backup manifest"
    echo "hostname: $(hostname)"
    echo "date_utc: $TIMESTAMP"
    echo "instance_id: $(curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown)"
    echo "paths_included:"
    for p in "${REL_PATHS[@]}"; do
      echo "  - /$p"
    done
    echo "paths_NOT_included:"
    echo "  - /root/.aws/credentials (secrets - kept only on Mac)"
    echo "  - /home/ubuntu/.aws/credentials (secrets - kept only on Mac)"
    echo "  - /etc/worxco/envs/* (regenerated by refresh-env-config on boot)"
  } > "$MANIFEST"

  # tar preserves ownership, mode, timestamps, symlinks by default.
  # -C / means "cd to / before archiving" - so archive contents look like:
  #   root/.ssh/id_ed25519
  #   home/ubuntu/.aws/config
  # On restore, `tar -xzf archive.tar.gz -C /` puts them back exactly.
  # We ALSO include the manifest at the root of the archive.
  if ! tar -czf "$LOCAL_ARCHIVE" \
        --transform "s|^${MANIFEST#/}|BACKUP-MANIFEST.txt|" \
        -C / \
        "${REL_PATHS[@]}" \
        "${MANIFEST#/}"; then
    log_error "tar failed. Removing partial archive."
    rm -f "$LOCAL_ARCHIVE" "$MANIFEST"
    exit 1
  fi
  rm -f "$MANIFEST"

  ARCHIVE_SIZE=$(stat -c %s "$LOCAL_ARCHIVE")
  log_ok "Archive created: $LOCAL_ARCHIVE ($((ARCHIVE_SIZE / 1024)) KB, includes BACKUP-MANIFEST.txt)"
fi

# ============================================================
# Phase 4 of 5: Upload to S3 (timestamped + latest pointer)
# ============================================================
log_step "Phase 4/5: Upload to S3"

TIMESTAMPED_KEY="$ARCHIVE_PREFIX/$ARCHIVE_NAME"

if is_dry_run; then
  log_info "[DRY_RUN] would upload:"
  log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$TIMESTAMPED_KEY (timestamped, 90-day retention)"
  log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$LATEST_KEY (latest, never expires)"
else
  # Upload the timestamped archive first - this is the durable copy.
  log_info "Uploading timestamped archive..."
  if ! aws s3 cp "$LOCAL_ARCHIVE" "s3://$DEPLOY_HOST_BACKUPS_BUCKET/$TIMESTAMPED_KEY" --quiet; then
    log_error "Timestamped upload failed"
    rm -f "$LOCAL_ARCHIVE"
    exit 1
  fi
  log_ok "Uploaded: s3://$DEPLOY_HOST_BACKUPS_BUCKET/$TIMESTAMPED_KEY"

  # Then S3-side copy to the latest pointer. Atomic on the S3 side.
  log_info "Updating latest pointer..."
  if ! aws s3 cp \
        "s3://$DEPLOY_HOST_BACKUPS_BUCKET/$TIMESTAMPED_KEY" \
        "s3://$DEPLOY_HOST_BACKUPS_BUCKET/$LATEST_KEY" \
        --quiet; then
    log_error "Latest pointer update failed"
    log_error "(Timestamped archive still uploaded successfully; you can"
    log_error " promote it manually with: aws s3 cp s3://.../$TIMESTAMPED_KEY s3://.../$LATEST_KEY)"
    exit 1
  fi
  log_ok "Updated: s3://$DEPLOY_HOST_BACKUPS_BUCKET/$LATEST_KEY"

  # Clean up local intermediate
  rm -f "$LOCAL_ARCHIVE"
  log_ok "Local intermediate removed: $LOCAL_ARCHIVE"
fi

# ============================================================
# Phase 5 of 5: Verify uploads
# ============================================================
log_step "Phase 5/5: Verify uploads"

if is_dry_run; then
  log_info "[DRY_RUN] would head-object both S3 keys"
else
  for key in "$TIMESTAMPED_KEY" "$LATEST_KEY"; do
    if S3_SIZE=$(aws s3api head-object \
                   --bucket "$DEPLOY_HOST_BACKUPS_BUCKET" --key "$key" \
                   --query ContentLength --output text 2>/dev/null); then
      log_ok "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$key ($((S3_SIZE / 1024)) KB)"
    else
      log_error "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$key NOT FOUND after upload"
      exit 1
    fi
  done
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "backup-state (deploy-host) - DRY RUN complete (no upload performed)"
  log_info "Would have archived ${#REL_PATHS[@]} paths (~$((TOTAL_BYTES / 1024)) KB)"
  log_info "Would have uploaded to:"
  log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$TIMESTAMPED_KEY"
  log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$LATEST_KEY"
else
  log_step "backup-state (deploy-host) complete"
  log_ok "Backup complete: ${#REL_PATHS[@]} paths archived"
  log_info "Restore with: make restore-deploy-host"
  log_info "List backups: make list-deploy-host-backups"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
