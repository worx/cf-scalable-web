#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/backup-state.sh
#
# Purpose:  Back up the jumpbox's operator-managed state (SSH keys,
#           .env files, custom bin/ directories, and /etc/worxco/)
#           to sandbox S3. Runs on-demand via `make backup-jumpbox`
#           OR nightly via EventBridge Scheduler.
#
#           Companion to restore-state.sh which pulls this back.
#           Together they protect against AMI-driven jumpbox
#           replacement — the biggest annoyance being having to
#           re-authorize a new SSH pubkey on React2.
#
# Flow (five phases, each logged separately):
#   1. Preconditions       (root, tools, AWS creds)
#   2. Enumerate paths     (skip & warn on missing per operator decision)
#   3. Create tarball      (gzip, /tmp intermediate, ownership preserved)
#   4. Upload to S3        (timestamped archive + latest pointer)
#   5. Verify              (head-object on both S3 objects)
#
# Backed-up paths (all optional — skip & warn if missing):
#   /root/.ssh/            SSH keys, known_hosts, authorized_keys
#   /root/.env             Env vars for root shell (if operator uses)
#   /root/bin/             Custom root scripts (if operator uses)
#   /home/ubuntu/.ssh/     SSH keys for ubuntu user
#   /home/ubuntu/.env      Env vars for ubuntu shell
#   /home/ubuntu/bin/      Custom ubuntu scripts
#   /etc/worxco/           WorxCo config (if operator uses)
#
# S3 layout produced:
#   s3://$MIGRATION_BUCKET/config/jumpbox-archive/jumpbox-<UTC>.tar.gz
#     └── timestamped durable copy; 90-day expiration via bucket lifecycle
#   s3://$MIGRATION_BUCKET/config/jumpbox-latest.tar.gz
#     └── S3-side copy of the newest timestamped archive; never expires;
#         auto-restore source for new jumpbox instances
#
# Idempotent:  Yes — each invocation writes a new timestamped archive
#              and overwrites the latest pointer atomically.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   Sandbox S3 bucket        (sandbox-migration-kv-worxco)
#   S3_PREFIX          Top-level prefix          (config)
#   CONFIRMED          (unused — backup is non-destructive; no prompt)
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  root on the jumpbox (needs read access to /root and privileged
#           /home/ubuntu subdirs; passwordless sudo on the AMI enables this)
# Host:     Prod jumpbox
# Called by:
#   - `make backup-jumpbox` (on-demand from Mac|DH via SSM send-command)
#   - EventBridge Scheduler nightly at 02:00 America/Chicago
#   - `make destroy-jumpbox` (pre-destroy final backup)
#
# Created:  2026-07-13
# ============================================================

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
S3_PREFIX="${S3_PREFIX:-config}"

# S3 object keys derived from the prefix
ARCHIVE_PREFIX="$S3_PREFIX/jumpbox-archive"
LATEST_KEY="$S3_PREFIX/jumpbox-latest.tar.gz"

# The set of paths we back up. Absolute paths; skip-and-warn if missing.
# Order matters only for log readability. If you add a path here, also
# add it to restore-state.sh's expected-path awareness (or better yet,
# have restore-state.sh derive it from the archive contents).
BACKUP_PATHS=(
  "/root/.ssh"
  "/root/.env"
  "/root/bin"
  "/home/ubuntu/.ssh"
  "/home/ubuntu/.env"
  "/home/ubuntu/bin"
  "/etc/worxco"
)

# ============================================================
# Set up logging + on-exit S3 upload of THIS script's log
# ============================================================
log_init "backup-state"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "backup-state — jumpbox state → sandbox S3"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "S3 destination:"
log_info "  s3://$MIGRATION_BUCKET/$ARCHIVE_PREFIX/  ← timestamped (90-day retention)"
log_info "  s3://$MIGRATION_BUCKET/$LATEST_KEY       ← latest pointer (never expires)"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 5: Preconditions
# ============================================================
log_step "Phase 1/5: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root — need read access to /root/.ssh and other privileged paths."
  log_error "Example: sudo -E ./backup-state.sh"
  exit 1
fi

require_env MIGRATION_BUCKET

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

# Build the list of REL_PATHS (paths without leading /) for `tar -C /`.
# Using -C / means tar records paths relative to / rather than absolute —
# safer on restore (no risk of accidentally overwriting arbitrary paths
# if the archive is ever extracted somewhere weird), and avoids the
# "Removing leading `/` from member names" tar warning.
REL_PATHS=()
TOTAL_BYTES=0
for path in "${BACKUP_PATHS[@]}"; do
  if [ -e "$path" ]; then
    SIZE=$(du -sb "$path" 2>/dev/null | cut -f1)
    REL_PATHS+=("${path#/}")   # strip leading /
    TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
    log_ok "  $path (${SIZE} bytes)"
  else
    log_warn "  $path — not found, skipping"
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
ARCHIVE_NAME="jumpbox-${TIMESTAMP}.tar.gz"
LOCAL_ARCHIVE="/tmp/$ARCHIVE_NAME"

log_info "Building $LOCAL_ARCHIVE"

if is_dry_run; then
  log_info "[DRY_RUN] would run: tar -czf $LOCAL_ARCHIVE -C / ${REL_PATHS[*]}"
else
  # tar preserves ownership, mode, timestamps, symlinks by default.
  # -C / means "cd to / before archiving" — so archive contents look like:
  #   root/.ssh/id_ed25519
  #   home/ubuntu/.ssh/id_ed25519
  # On restore, `tar -xzf archive.tar.gz -C /` puts them back exactly.
  if ! tar -czf "$LOCAL_ARCHIVE" -C / "${REL_PATHS[@]}"; then
    log_error "tar failed. Removing partial archive."
    rm -f "$LOCAL_ARCHIVE"
    exit 1
  fi

  ARCHIVE_SIZE=$(stat -c %s "$LOCAL_ARCHIVE")
  log_ok "Archive created: $LOCAL_ARCHIVE ($((ARCHIVE_SIZE / 1024)) KB)"
fi

# ============================================================
# Phase 4 of 5: Upload to S3 (timestamped + latest pointer)
# ============================================================
log_step "Phase 4/5: Upload to S3"

TIMESTAMPED_KEY="$ARCHIVE_PREFIX/$ARCHIVE_NAME"

if is_dry_run; then
  log_info "[DRY_RUN] would upload:"
  log_info "  s3://$MIGRATION_BUCKET/$TIMESTAMPED_KEY (timestamped, 90-day retention)"
  log_info "  s3://$MIGRATION_BUCKET/$LATEST_KEY (latest, never expires)"
else
  # Upload the timestamped archive first — this is the durable copy.
  log_info "Uploading timestamped archive..."
  if ! aws s3 cp "$LOCAL_ARCHIVE" "s3://$MIGRATION_BUCKET/$TIMESTAMPED_KEY" --quiet; then
    log_error "Timestamped upload failed"
    rm -f "$LOCAL_ARCHIVE"
    exit 1
  fi
  log_ok "Uploaded: s3://$MIGRATION_BUCKET/$TIMESTAMPED_KEY"

  # Then S3-side copy to the latest pointer. This is atomic on the S3
  # side (no window where the latest pointer is missing or partial),
  # and cheaper than a second upload since S3 does the work.
  log_info "Updating latest pointer..."
  if ! aws s3 cp \
        "s3://$MIGRATION_BUCKET/$TIMESTAMPED_KEY" \
        "s3://$MIGRATION_BUCKET/$LATEST_KEY" \
        --quiet; then
    log_error "Latest pointer update failed"
    log_error "(Timestamped archive still uploaded successfully; you can"
    log_error " promote it manually with: aws s3 cp s3://.../$TIMESTAMPED_KEY s3://.../$LATEST_KEY)"
    exit 1
  fi
  log_ok "Updated: s3://$MIGRATION_BUCKET/$LATEST_KEY"

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
                   --bucket "$MIGRATION_BUCKET" --key "$key" \
                   --query ContentLength --output text 2>/dev/null); then
      log_ok "  s3://$MIGRATION_BUCKET/$key ($((S3_SIZE / 1024)) KB)"
    else
      log_error "  s3://$MIGRATION_BUCKET/$key NOT FOUND after upload"
      exit 1
    fi
  done
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "backup-state — DRY RUN complete (no upload performed)"
  log_info "Would have archived ${#REL_PATHS[@]} paths (~$((TOTAL_BYTES / 1024)) KB)"
  log_info "Would have uploaded to:"
  log_info "  s3://$MIGRATION_BUCKET/$TIMESTAMPED_KEY"
  log_info "  s3://$MIGRATION_BUCKET/$LATEST_KEY"
else
  log_step "backup-state complete"
  log_ok "Backup complete: ${#REL_PATHS[@]} paths archived"
  log_info "Restore with: cd migration && make restore-jumpbox"
  log_info "List backups: cd migration && make list-jumpbox-backups"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
