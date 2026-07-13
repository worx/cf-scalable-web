#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/restore-state.sh
#
# Purpose:  Restore the jumpbox's operator-managed state (SSH keys,
#           .env files, custom bin/ directories, /etc/worxco/) from
#           the sandbox S3 backup that `backup-state.sh` produced.
#
#           Two invocation modes:
#             1. Manual on-demand via `make restore-jumpbox`
#             2. Automatic in UserData at first-boot of a new instance
#
# Safety net (Kurt's request):
#   Before extracting the S3 archive, the script tars whatever's
#   currently at the target paths into
#     /tmp/pre-restore-backup-<UTC>.tar.gz
#   giving you an "undo" if the restore turned out to be wrong.
#   Prints the exact undo command at the end.
#
# Flow (six phases):
#   1. Preconditions        (root, tools, AWS creds, S3 backup exists)
#   2. Snapshot current     (tar current state → /tmp — the safety net)
#   3. Fetch S3 archive     (download latest or a specified archive)
#   4. Extract              (tar xzf ... -C /)
#   5. Verify               (spot-check known paths landed)
#   6. Announce undo cmd    (print how to reverse if needed)
#
# Idempotent: yes — extracting the same archive twice is a no-op
#   (tar overwrites with identical content). The pre-restore snapshot
#   is timestamped separately per invocation so history isn't lost.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   Sandbox S3 bucket        (sandbox-migration-kv-worxco)
#   S3_PREFIX          Top-level prefix          (config)
#   RESTORE_KEY        S3 key to restore FROM    (<prefix>/jumpbox-latest.tar.gz)
#   SKIP_SNAPSHOT      yes = skip the /tmp safety-net snapshot (dangerous)
#   CONFIRMED          yes = skip Y/N confirmation prompt
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  root on the jumpbox
# Host:     Prod jumpbox
# Called by:
#   - `make restore-jumpbox` (on-demand from Mac|DH via SSM send-command)
#   - UserData at first boot (via CFN — with CONFIRMED=yes and if latest exists)
#
# Undo:
#   sudo tar -xzf /tmp/pre-restore-backup-<UTC>.tar.gz -C /
#   (script prints the exact command with the actual timestamp)
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
RESTORE_KEY="${RESTORE_KEY:-$S3_PREFIX/jumpbox-latest.tar.gz}"
SKIP_SNAPSHOT="${SKIP_SNAPSHOT:-}"

# The set of paths we know backup-state.sh tracks — used for the
# pre-restore snapshot. If any of these currently exists on the
# jumpbox, we tar it before extracting the S3 archive.
KNOWN_PATHS=(
  "/root/.ssh"
  "/root/.env"
  "/root/bin"
  "/home/ubuntu/.ssh"
  "/home/ubuntu/.env"
  "/home/ubuntu/bin"
  "/etc/worxco"
)

# The paths we verify after restore (spot-check that extraction worked)
VERIFY_PATHS=(
  "/root/.ssh/id_ed25519"   # The critical one — React2 SSH access
)

# ============================================================
# Set up logging + on-exit S3 upload of THIS script's log
# ============================================================
log_init "restore-state"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "restore-state — sandbox S3 → jumpbox state"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "RESTORE_KEY      = $RESTORE_KEY"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi
if [ "$SKIP_SNAPSHOT" = "yes" ]; then
  log_warn "SKIP_SNAPSHOT=yes — the /tmp pre-restore snapshot will NOT be taken."
  log_warn "You will have no local undo path. Continue only if you know what you're doing."
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root — need write access to /root, /home/ubuntu, /etc."
  log_error "Example: sudo -E ./restore-state.sh"
  exit 1
fi

require_env MIGRATION_BUCKET RESTORE_KEY

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

# The S3 archive we're about to restore MUST exist. Check before we
# take a pre-restore snapshot (no point snapshotting if there's nothing
# to restore from).
if is_dry_run; then
  log_info "[DRY_RUN] would head-object s3://$MIGRATION_BUCKET/$RESTORE_KEY"
elif ! aws s3api head-object \
       --bucket "$MIGRATION_BUCKET" --key "$RESTORE_KEY" >/dev/null 2>&1; then
  log_error "Source archive does not exist: s3://$MIGRATION_BUCKET/$RESTORE_KEY"
  log_error "  Either no prior backup exists, or the key/bucket is wrong."
  log_error "  On a fresh migration, this is EXPECTED — just skip restore."
  exit 1
fi

log_ok "Preconditions satisfied — source archive exists"

# ============================================================
# Phase 2 of 6: Snapshot current state (the /tmp safety net)
# ============================================================
log_step "Phase 2/6: Snapshot current state (undo safety net)"

TIMESTAMP=$(date -u +%Y%m%d-%H%M%SZ)
PRE_RESTORE_ARCHIVE="/tmp/pre-restore-backup-${TIMESTAMP}.tar.gz"

if [ "$SKIP_SNAPSHOT" = "yes" ]; then
  log_warn "Skipping pre-restore snapshot (SKIP_SNAPSHOT=yes)"
  PRE_RESTORE_ARCHIVE=""
else
  # Enumerate what CURRENTLY exists at each known path
  REL_PATHS=()
  for path in "${KNOWN_PATHS[@]}"; do
    if [ -e "$path" ]; then
      REL_PATHS+=("${path#/}")
      log_info "  $path (will be snapshotted)"
    else
      log_info "  $path (not present — nothing to snapshot)"
    fi
  done

  if [ ${#REL_PATHS[@]} -eq 0 ]; then
    # Nothing on the current instance — clean slate. Snapshot would be
    # empty. That's fine but we still create it so the undo path exists.
    log_info "No current state to snapshot (fresh instance?). Creating empty marker archive."
    if ! is_dry_run; then
      # tar refuses to create an empty archive from an empty list; give
      # it a single innocuous entry so the file exists.
      echo "empty snapshot: no prior state on this instance" > /tmp/.snapshot-marker
      tar -czf "$PRE_RESTORE_ARCHIVE" -C /tmp .snapshot-marker
      rm -f /tmp/.snapshot-marker
    fi
  else
    log_info "Building pre-restore snapshot: $PRE_RESTORE_ARCHIVE"
    if is_dry_run; then
      log_info "[DRY_RUN] would run: tar -czf $PRE_RESTORE_ARCHIVE -C / ${REL_PATHS[*]}"
    else
      if ! tar -czf "$PRE_RESTORE_ARCHIVE" -C / "${REL_PATHS[@]}"; then
        log_error "Pre-restore snapshot failed. Aborting so we don't lose the undo path."
        rm -f "$PRE_RESTORE_ARCHIVE"
        exit 1
      fi
      SNAP_SIZE=$(stat -c %s "$PRE_RESTORE_ARCHIVE")
      log_ok "Snapshot created: $PRE_RESTORE_ARCHIVE ($((SNAP_SIZE / 1024)) KB)"
    fi
  fi
fi

# ============================================================
# Phase 3 of 6: Fetch S3 archive
# ============================================================
log_step "Phase 3/6: Fetch S3 archive"

DOWNLOAD_PATH="/tmp/restore-source-${TIMESTAMP}.tar.gz"

if is_dry_run; then
  log_info "[DRY_RUN] would run: aws s3 cp s3://$MIGRATION_BUCKET/$RESTORE_KEY $DOWNLOAD_PATH"
else
  log_info "Downloading s3://$MIGRATION_BUCKET/$RESTORE_KEY"
  if ! aws s3 cp "s3://$MIGRATION_BUCKET/$RESTORE_KEY" "$DOWNLOAD_PATH" --quiet; then
    log_error "S3 download failed. Aborting."
    log_error "Pre-restore snapshot is still at: ${PRE_RESTORE_ARCHIVE:-<none>}"
    rm -f "$DOWNLOAD_PATH"
    exit 1
  fi
  DOWNLOAD_SIZE=$(stat -c %s "$DOWNLOAD_PATH")
  log_ok "Downloaded: $DOWNLOAD_PATH ($((DOWNLOAD_SIZE / 1024)) KB)"
fi

# ============================================================
# Phase 4 of 6: Extract to /
# ============================================================
log_step "Phase 4/6: Extract to /"

if is_dry_run; then
  log_info "[DRY_RUN] would run: tar -xzf $DOWNLOAD_PATH -C /"
  log_info "[DRY_RUN] would then run: rm -f $DOWNLOAD_PATH"
else
  # Preserve ownership + permissions (default for tar as root)
  if ! tar -xzf "$DOWNLOAD_PATH" -C /; then
    log_error "tar extract failed."
    log_error "Undo command (restore prior state):"
    if [ -n "$PRE_RESTORE_ARCHIVE" ] && [ -f "$PRE_RESTORE_ARCHIVE" ]; then
      log_error "  sudo tar -xzf $PRE_RESTORE_ARCHIVE -C /"
    else
      log_error "  (no pre-restore snapshot available)"
    fi
    rm -f "$DOWNLOAD_PATH"
    exit 1
  fi
  log_ok "Archive extracted to /"

  # Clean up the downloaded intermediate
  rm -f "$DOWNLOAD_PATH"
fi

# ============================================================
# Phase 5 of 6: Verify (spot-check known paths)
# ============================================================
log_step "Phase 5/6: Verify restoration"

if is_dry_run; then
  log_info "[DRY_RUN] would verify presence of: ${VERIFY_PATHS[*]}"
else
  MISSING=()
  for vp in "${VERIFY_PATHS[@]}"; do
    if [ -e "$vp" ]; then
      log_ok "  $vp present"
    else
      log_warn "  $vp NOT present after restore"
      MISSING+=("$vp")
    fi
  done

  # If a critical path is missing, that's a real problem — but don't
  # auto-undo. Print the recovery command and let the operator decide.
  if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Critical paths missing after restore:"
    for m in "${MISSING[@]}"; do
      log_error "  $m"
    done
    log_error "The archive may not contain what we expected. To undo:"
    if [ -n "$PRE_RESTORE_ARCHIVE" ] && [ -f "$PRE_RESTORE_ARCHIVE" ]; then
      log_error "  sudo tar -xzf $PRE_RESTORE_ARCHIVE -C /"
    else
      log_error "  (no pre-restore snapshot — you're on your own)"
    fi
    exit 1
  fi
fi

# ============================================================
# Phase 6 of 6: Announce undo
# ============================================================
log_step "Phase 6/6: Announce undo path"

if is_dry_run; then
  log_info "[DRY_RUN] would print undo command referencing $PRE_RESTORE_ARCHIVE"
else
  if [ -n "$PRE_RESTORE_ARCHIVE" ] && [ -f "$PRE_RESTORE_ARCHIVE" ]; then
    log_info "Pre-restore snapshot preserved at: $PRE_RESTORE_ARCHIVE"
    log_info "To undo this restore:"
    log_info "  sudo tar -xzf $PRE_RESTORE_ARCHIVE -C /"
    log_info ""
    log_info "The snapshot lives on /tmp and will be cleared on reboot."
    log_info "If you want to keep it, copy it out now."
  else
    log_warn "No pre-restore snapshot was taken (SKIP_SNAPSHOT=yes). No undo path available."
  fi
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "restore-state — DRY RUN complete (no changes made)"
  log_info "Would have restored ${#KNOWN_PATHS[@]} tracked path locations from"
  log_info "  s3://$MIGRATION_BUCKET/$RESTORE_KEY"
else
  log_step "restore-state complete"
  log_ok "Jumpbox state restored from s3://$MIGRATION_BUCKET/$RESTORE_KEY"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
