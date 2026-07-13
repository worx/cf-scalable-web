#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/dump-private.sh
#
# Purpose:  Tar the client's Drupal PRIVATE files directory on React2
#           (typically small — just an .htaccess deny-all and any
#           private uploads) and stream to the sandbox S3 migration
#           bucket. On many sites this ends up nearly-empty; the
#           dump still runs for completeness so restore-private is a
#           deterministic step.
#
# Flow (six phases, mirrors dump-codebase.sh and dump-files.sh):
#   1. Preconditions       (root, tools, SSH key, AWS creds)
#   2. Test SSH            (jumpbox → React2 as ubuntu)
#   3. Source metadata     (approximate private/ size on React2)
#   4. Confirmation        (honors CONFIRMED=yes)
#   5. Stream tar → S3     (ssh "tar cz" | aws s3 cp -)
#   6. Verify S3 upload
#
# Idempotent: yes — S3 PUT is atomic; no local intermediate.
#
# NOTE: `private/` on many Drupal sites is essentially empty (just an
#   .htaccess and maybe some CSV imports). Compressed tar can be under
#   1 KB — the size-sanity check in Phase 6 is relaxed accordingly.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   Sandbox S3 bucket        (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Target object key         (dumps/drupal-private.tar.gz)
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
#   - Directly (`sudo ./dump-private.sh` in an SSM session)
#   - By a future `make dump-private` Makefile target
#
# Created:  2026-07-13
# ============================================================

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/drupal-private.tar.gz}"
SOURCE_HOST="${SOURCE_HOST:-172.31.23.46}"
SOURCE_USER="${SOURCE_USER:-ubuntu}"
DRUPAL_ROOT="${DRUPAL_ROOT:-/var/www/html/zoning_info_platform}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_ed25519}"

# What to tar and from where. For the private directory:
#   -C DRUPAL_ROOT   private
# so the archive contains `private/` at the root, matching how
# restore-private.sh will extract it.
TAR_CWD="$DRUPAL_ROOT"
TAR_TARGET="private"

# ============================================================
# Set up logging + on-exit S3 upload
# ============================================================
log_init "dump-private"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "dump-private — React2 private files → sandbox S3"
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
  log_error "Example: sudo -E ./dump-private.sh"
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
  log_error "Some sites don't use a private-files directory. If that's the case,"
  log_error "skip this step and don't run restore-private on the sandbox side either."
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
  TOTAL_KB=0
else
  TOTAL_KB=$(( TOTAL_SIZE / 1024 ))
  log_info "Source $TAR_CWD/$TAR_TARGET:"
  log_info "  Size:  ~${TOTAL_KB} KB (${TOTAL_SIZE} bytes)"
  log_info "  Files: $FILE_COUNT"
  if [ "$FILE_COUNT" -le 1 ]; then
    log_info "  (essentially empty — just an .htaccess or similar)"
  fi
fi

# ============================================================
# Phase 4 of 6: Confirmation
# ============================================================
log_step "Phase 4/6: Confirmation"

confirm_or_exit "About to tar the Drupal PRIVATE files directory on React2 and stream to sandbox S3.
    Source: $SOURCE_USER@$SOURCE_HOST:$TAR_CWD/$TAR_TARGET (~${TOTAL_KB} KB, ${FILE_COUNT} files)
    Target: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Impact: usually negligible — private/ tends to be small."

# ============================================================
# Phase 5 of 6: Stream tar over SSH → S3
# ============================================================
log_step "Phase 5/6: tar over SSH → S3 stream"

log_info "Starting tar stream: React2 → S3"

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

  # Relaxed size check — private/ can be legitimately tiny (a bare
  # .htaccess produces a tar under 500 bytes). Only fail if the object
  # is smaller than an empty gzipped tar header (~50 bytes).
  if [ "$S3_SIZE" -lt 50 ]; then
    log_error "S3 object is only $S3_SIZE bytes — smaller than an empty tar."
    log_error "Something went wrong. Investigate."
    exit 1
  fi

  # Human-readable size formatting for a typically-small object
  if [ "$S3_SIZE" -lt 1024 ]; then
    log_ok "S3 object: ${S3_SIZE} bytes at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  elif [ "$S3_SIZE" -lt 1048576 ]; then
    log_ok "S3 object: $(( S3_SIZE / 1024 )) KB at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  else
    log_ok "S3 object: $(( S3_SIZE / 1024 / 1024 )) MB at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  fi
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "dump-private — DRY RUN complete (no upload performed)"
  log_info "Would have uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Re-run without DRY_RUN=yes to perform the actual tar+upload."
else
  log_step "dump-private complete"
  log_ok "Private tarball uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Next: on deploy-host, run 'cd migration && make restore-private'"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
