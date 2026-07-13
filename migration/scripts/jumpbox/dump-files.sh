#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/dump-files.sh
#
# Purpose:  Tar the client's public user-uploads directory
#           (web/sites/default/files) on React2 and stream the archive
#           directly to the sandbox S3 migration bucket. This is
#           typically the largest of the three tar streams — Drupal
#           sites accumulate images, PDFs, and attachments over time.
#
# Flow (six phases):
#   1. Preconditions       (root, tools, SSH key, AWS creds)
#   2. Test SSH            (jumpbox → React2 as ubuntu)
#   3. Source metadata     (approximate files/ size on React2)
#   4. Confirmation        (honors CONFIRMED=yes; warns about time)
#   5. Stream tar → S3     (ssh "tar cz" | aws s3 cp -)
#   6. Verify S3 upload
#
# Idempotent: yes — S3 PUT is atomic and overwrites the previous
#   object; no local intermediate on the jumpbox.
#
# NOTE on compression: files/ is largely pre-compressed content
#   (JPEG, PDF, PNG). Gzip won't shrink much (~10-15% typical), but
#   keeping the same tar.gz format as dump-codebase.sh means restore
#   scripts use one extract pattern uniformly. Bandwidth savings from
#   even mild compression are still real on gigabyte transfers.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   Sandbox S3 bucket        (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Target object key         (dumps/drupal-files.tar.gz)
#   SOURCE_HOST        React2 IP or hostname     (172.31.23.46)
#   SOURCE_USER        SSH user on React2        (ubuntu)
#   DRUPAL_ROOT        Codebase root on React2   (/var/www/html/zoning_info_platform)
#   SSH_KEY            SSH private key location  (/root/.ssh/id_ed25519)
#   CONFIRMED          yes = skip Y/N confirmation
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  root on the jumpbox
# Host:     Prod jumpbox
# Called by:
#   - Directly (in an SSM interactive session, `sudo ./dump-files.sh`)
#   - By a future `make dump-files` Makefile target (SSM send-command)
#
# Created:  2026-07-13
# ============================================================

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/drupal-files.tar.gz}"
SOURCE_HOST="${SOURCE_HOST:-172.31.23.46}"
SOURCE_USER="${SOURCE_USER:-ubuntu}"
DRUPAL_ROOT="${DRUPAL_ROOT:-/var/www/html/zoning_info_platform}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_ed25519}"

# What to tar and from where. For the files directory:
#   -C DRUPAL_ROOT/web/sites/default   files
# so the archive contains `files/` at the root — matches how
# restore-files.sh will extract it (into web/sites/default/).
TAR_CWD="$DRUPAL_ROOT/web/sites/default"
TAR_TARGET="files"

# ============================================================
# Set up logging + on-exit S3 upload
# ============================================================
log_init "dump-files"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "dump-files — React2 public files → sandbox S3"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "DUMP_S3_KEY      = $DUMP_S3_KEY"
log_info "SOURCE_HOST      = $SOURCE_HOST"
log_info "SOURCE_USER      = $SOURCE_USER"
log_info "TAR source       = $SOURCE_USER@$SOURCE_HOST:$TAR_CWD/$TAR_TARGET"
log_info "SSH_KEY          = $SSH_KEY"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root — the SSH key at $SSH_KEY belongs to root."
  log_error "Example: sudo -E ./dump-files.sh"
  exit 1
fi

require_env MIGRATION_BUCKET DUMP_S3_KEY SOURCE_HOST SOURCE_USER DRUPAL_ROOT SSH_KEY

for tool in ssh tar aws; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    exit 1
  fi
done

if [ ! -f "$SSH_KEY" ]; then
  log_error "SSH private key not found at $SSH_KEY"
  log_error "From your Mac or deploy-host, run:"
  log_error "  cd migration && make jumpbox-pubkey"
  exit 1
fi

if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  log_error "AWS credentials are not working. Check instance role attachment."
  exit 1
fi

log_ok "Preconditions satisfied"

# ============================================================
# Phase 2 of 6: Test SSH connectivity to React2
# ============================================================
log_step "Phase 2/6: Test SSH to $SOURCE_USER@$SOURCE_HOST"

if ! ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "$SOURCE_USER@$SOURCE_HOST" "hostname; whoami" >/dev/null 2>&1; then
  log_error "Cannot SSH to $SOURCE_USER@$SOURCE_HOST"
  log_error "Check jumpbox pubkey is in React2's ~$SOURCE_USER/.ssh/authorized_keys"
  exit 1
fi

REMOTE_HOSTNAME=$(ssh -i "$SSH_KEY" -o BatchMode=yes "$SOURCE_USER@$SOURCE_HOST" hostname)
log_ok "SSH working — connected to $REMOTE_HOSTNAME as $SOURCE_USER"

# Sanity: the target directory actually exists on React2
if ! ssh -i "$SSH_KEY" -o BatchMode=yes "$SOURCE_USER@$SOURCE_HOST" \
     "sudo test -d '$TAR_CWD/$TAR_TARGET'" >/dev/null 2>&1; then
  log_error "Directory does not exist on React2: $TAR_CWD/$TAR_TARGET"
  log_error "Check DRUPAL_ROOT is correct for this site."
  exit 1
fi
log_ok "Target directory exists on React2"

# ============================================================
# Phase 3 of 6: Fetch source metadata
# ============================================================
log_step "Phase 3/6: Fetch source metadata"

TOTAL_SIZE=$(ssh -i "$SSH_KEY" -o BatchMode=yes "$SOURCE_USER@$SOURCE_HOST" \
  "sudo du -sb '$TAR_CWD/$TAR_TARGET' 2>/dev/null | cut -f1" || echo "0")

FILE_COUNT=$(ssh -i "$SSH_KEY" -o BatchMode=yes "$SOURCE_USER@$SOURCE_HOST" \
  "sudo find '$TAR_CWD/$TAR_TARGET' -type f 2>/dev/null | wc -l" || echo "0")

if [ "$TOTAL_SIZE" = "0" ] || [ -z "$TOTAL_SIZE" ]; then
  log_warn "Could not measure source size. Proceeding anyway."
  TOTAL_MB=0
else
  TOTAL_MB=$(( TOTAL_SIZE / 1024 / 1024 ))
  log_info "Source $TAR_CWD/$TAR_TARGET:"
  log_info "  Size:  ~${TOTAL_MB} MB"
  log_info "  Files: $FILE_COUNT"
  if [ "$TOTAL_MB" -gt 5000 ]; then
    log_warn "Files directory > 5 GB — this transfer may take 30+ minutes."
  fi
fi

# ============================================================
# Phase 4 of 6: Confirmation
# ============================================================
log_step "Phase 4/6: Confirmation"

confirm_or_exit "About to tar the Drupal files directory on React2 and stream to sandbox S3.
    Source: $SOURCE_USER@$SOURCE_HOST:$TAR_CWD/$TAR_TARGET
            (~${TOTAL_MB} MB, ${FILE_COUNT} files)
    Target: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Impact: sustained read I/O on React2 for the tar duration
    (could be 10-60+ minutes depending on size)."

# ============================================================
# Phase 5 of 6: Stream tar over SSH → S3
# ============================================================
log_step "Phase 5/6: tar over SSH → S3 stream"

log_info "Starting tar stream: React2 → S3"
log_info "(this is typically the longest of the three tar streams)"

if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  log_info "  ssh $SOURCE_USER@$SOURCE_HOST \\"
  log_info "    \"sudo tar czf - -C '$TAR_CWD' $TAR_TARGET\" \\"
  log_info "    | aws s3 cp - s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
else
  time_start=$SECONDS

  if ! ssh -i "$SSH_KEY" -o BatchMode=yes "$SOURCE_USER@$SOURCE_HOST" \
        "sudo tar czf - -C '$TAR_CWD' '$TAR_TARGET'" \
      | aws s3 cp - "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  then
    log_error "Tar/upload pipeline failed. Removing partial S3 object..."
    aws s3 rm "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY" 2>/dev/null || true
    exit 1
  fi

  time_elapsed=$(( SECONDS - time_start ))
  log_ok "Tar stream completed in ${time_elapsed}s"
fi

# ============================================================
# Phase 6 of 6: Verify S3 upload
# ============================================================
log_step "Phase 6/6: Verify S3 upload"

if is_dry_run; then
  log_info "[DRY_RUN] would run: aws s3api head-object ..."
else
  S3_SIZE=$(aws s3api head-object \
      --bucket "$MIGRATION_BUCKET" --key "$DUMP_S3_KEY" \
      --query ContentLength --output text 2>/dev/null || echo "0")

  if [ "$S3_SIZE" = "0" ] || [ -z "$S3_SIZE" ]; then
    log_error "S3 object does not exist or head-object failed."
    exit 1
  fi

  # A files/ tarball for a real Drupal site with any user activity
  # is essentially always ≥ 1 MB. Sub-1MB likely means a broken pipe.
  # (Sites with genuinely empty files/ dirs would be caught in Phase 3.)
  if [ "$S3_SIZE" -lt 1048576 ] && [ "$TOTAL_MB" -gt 1 ]; then
    log_error "S3 object is only $S3_SIZE bytes but source was ${TOTAL_MB} MB — suspicious."
    log_error "Investigate before running restore-files on the sandbox side."
    exit 1
  fi

  S3_MB=$(( S3_SIZE / 1024 / 1024 ))
  if [ "$TOTAL_MB" -gt 0 ]; then
    RATIO=$(( S3_MB * 100 / TOTAL_MB ))
    log_ok "S3 object: ${S3_MB} MB at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
    log_info "Compression ratio: ${S3_MB} MB / ${TOTAL_MB} MB ≈ ${RATIO}%"
    log_info "(pre-compressed content like images typically compresses 85-95%)"
  else
    log_ok "S3 object: ${S3_MB} MB at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  fi
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "dump-files — DRY RUN complete (no upload performed)"
  log_info "Would have uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Re-run without DRY_RUN=yes to perform the actual tar+upload."
else
  log_step "dump-files complete"
  log_ok "Files tarball uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Next: on deploy-host, run 'cd migration && make restore-files'"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
