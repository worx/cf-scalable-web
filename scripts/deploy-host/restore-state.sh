#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/deploy-host/restore-state.sh
#
# Purpose:  Restore deploy-host operator-managed state from the sandbox
#           deploy-host backups S3 bucket. Includes a safety-net
#           snapshot to /tmp before extracting, and writes stub
#           .aws/credentials files pointing back to the Mac for the
#           real credentials.
#
# Two invocation modes:
#   1. Manual on-demand via `make restore-deploy-host`
#   2. Automatic in UserData at first-boot of a new deploy-host
#
# Safety net (matches jumpbox pattern):
#   Before extracting the S3 archive, the script tars whatever's
#   currently at the target paths into
#     /tmp/pre-restore-backup-<UTC>.tar.gz
#   giving an undo path if the restore was wrong.
#
# Credentials stub (deploy-host-specific behavior):
#   After extraction, if /root/.aws/credentials or /home/ubuntu/.aws/credentials
#   do NOT exist (they were deliberately excluded from backup), create
#   a stub file at each path with a clear message directing the
#   operator to their Mac. This makes it obvious what's missing
#   instead of getting silent "profile not found" errors later.
#
# Flow (seven phases):
#   1. Preconditions        (root, tools, AWS creds, S3 backup exists)
#   2. Snapshot current     (tar current state → /tmp - safety net)
#   3. Fetch S3 archive     (download latest or specified archive)
#   4. Extract              (tar xzf ... -C /)
#   5. Write credentials stubs (only where missing)
#   6. Verify               (spot-check known paths landed)
#   7. Announce undo cmd    (print how to reverse if needed)
#
# Idempotent: yes - extracting the same archive twice is a no-op.
#   Stub file creation only happens if credentials file is absent.
#
# Environment variables (all optional, listed with defaults):
#   DEPLOY_HOST_BACKUPS_BUCKET   Bucket    (sandbox-deploy-host-backups-kv-worxco)
#   S3_PREFIX                    Top-level (config)
#   RESTORE_KEY                  Object key (<prefix>/deploy-host-latest.tar.gz)
#   SKIP_SNAPSHOT                yes = skip pre-restore snapshot (dangerous)
#   SKIP_CREDENTIALS_STUB        yes = do not create .aws/credentials stubs
#   CONFIRMED                    yes = skip Y/N confirmation
#   DRY_RUN                      yes = preview without executing
#
# Runs as:  root on deploy-host
# Host:     deploy-host (sandbox VPC)
# Called by:
#   - `make restore-deploy-host` (on-demand)
#   - UserData at first boot (via cf-deploy-host.yaml)
#
# Undo:
#   sudo tar -xzf /tmp/pre-restore-backup-<UTC>.tar.gz -C /
#   (script prints the exact command with the actual timestamp)
#
# Created:  2026-07-15
# ============================================================

set -euo pipefail

# Source shared helpers (same lookup as backup-state.sh)
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/_common.sh" ]; then
  # Standalone or same-dir layout
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/_common.sh"
elif [ -f "$SCRIPT_DIR/../_common.sh" ]; then
  # SSM-uploaded layout: _common.sh at /opt/deploy-host/scripts/
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../_common.sh"
elif [ -f "$SCRIPT_DIR/../../migration/scripts/_common.sh" ]; then
  # Repo layout fallback
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
RESTORE_KEY="${RESTORE_KEY:-$S3_PREFIX/deploy-host-latest.tar.gz}"
SKIP_SNAPSHOT="${SKIP_SNAPSHOT:-}"
SKIP_CREDENTIALS_STUB="${SKIP_CREDENTIALS_STUB:-}"

# Paths the backup tracks (used for pre-restore snapshot enumeration).
# Must stay in sync with BACKUP_PATHS in backup-state.sh - if a path
# appears in the archive but not here, the pre-restore /tmp snapshot
# won't capture it, so the undo path would be incomplete. See
# backup-state.sh's header comment for detailed rationale on each
# category.
KNOWN_PATHS=(
  # Access / identity
  "/root/.ssh"
  "/home/ubuntu/.ssh"
  "/home/ubuntu/.gitconfig"

  # Operator env vars and custom scripts
  "/root/.env"
  "/root/bin"
  "/home/ubuntu/.env"
  "/home/ubuntu/bin"

  # AWS CLI config (NOT credentials)
  "/root/.aws/config"
  "/home/ubuntu/.aws/config"

  # Active env marker (bootstrap.sh remount step reads this)
  "/etc/worxco/current-env"

  # Shell dotfiles
  "/root/.bashrc"
  "/root/.profile"
  "/home/ubuntu/.bashrc"
  "/home/ubuntu/.profile"

  # Shell + tool history
  "/root/.zsh_history"
  "/root/.mysql_history"
  "/home/ubuntu/.zsh_history"

  # Operator-configured tools
  "/root/.config/htop"
  "/home/ubuntu/.config/htop"

  # Quality-of-life markers
  "/home/ubuntu/.sudo_as_admin_successful"
)

# Post-restore verification: at least one of these should be present
VERIFY_PATHS=(
  "/root/.ssh"
)

# Credentials stub locations + owners
CREDENTIALS_STUBS=(
  "/root/.aws/credentials:root:root:600"
  "/home/ubuntu/.aws/credentials:ubuntu:ubuntu:600"
)

# ============================================================
# Set up logging + on-exit S3 upload of THIS script's log
# ============================================================
log_init "restore-state-deploy-host"
trap 'log_upload_and_exit "$DEPLOY_HOST_BACKUPS_BUCKET"' EXIT

log_step "restore-state (deploy-host) - sandbox S3 → deploy-host state"
log_info "DEPLOY_HOST_BACKUPS_BUCKET = $DEPLOY_HOST_BACKUPS_BUCKET"
log_info "RESTORE_KEY                = $RESTORE_KEY"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes - commands will be previewed, not executed"
fi
if [ "$SKIP_SNAPSHOT" = "yes" ]; then
  log_warn "SKIP_SNAPSHOT=yes - no /tmp undo path will be created"
fi

# ============================================================
# Phase 1 of 7: Preconditions
# ============================================================
log_step "Phase 1/7: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root - need write access to /root, /home/ubuntu."
  log_error "Example: sudo -E ./restore-state.sh"
  exit 1
fi

require_env DEPLOY_HOST_BACKUPS_BUCKET RESTORE_KEY

for tool in tar aws du stat install; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    exit 1
  fi
done

if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  log_error "AWS credentials not working. Check instance role attachment."
  exit 1
fi

if is_dry_run; then
  log_info "[DRY_RUN] would head-object s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY"
elif ! aws s3api head-object \
       --bucket "$DEPLOY_HOST_BACKUPS_BUCKET" --key "$RESTORE_KEY" >/dev/null 2>&1; then
  log_error "Source archive does not exist: s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY"
  log_error "  On a fresh deploy-host with no prior backup, this is EXPECTED - skip restore."
  exit 1
fi

log_ok "Preconditions satisfied - source archive exists"

# ============================================================
# Phase 2 of 7: Snapshot current state (the /tmp safety net)
# ============================================================
log_step "Phase 2/7: Snapshot current state (undo safety net)"

TIMESTAMP=$(date -u +%Y%m%d-%H%M%SZ)
PRE_RESTORE_ARCHIVE="/tmp/pre-restore-backup-${TIMESTAMP}.tar.gz"

if [ "$SKIP_SNAPSHOT" = "yes" ]; then
  log_warn "Skipping pre-restore snapshot (SKIP_SNAPSHOT=yes)"
  PRE_RESTORE_ARCHIVE=""
else
  REL_PATHS=()
  for path in "${KNOWN_PATHS[@]}"; do
    if [ -e "$path" ]; then
      REL_PATHS+=("${path#/}")
      log_info "  $path (will be snapshotted)"
    else
      log_info "  $path (not present - nothing to snapshot)"
    fi
  done

  if [ ${#REL_PATHS[@]} -eq 0 ]; then
    log_info "No current state to snapshot (fresh instance). Creating marker archive."
    if ! is_dry_run; then
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
        log_error "Pre-restore snapshot failed. Aborting to preserve undo path."
        rm -f "$PRE_RESTORE_ARCHIVE"
        exit 1
      fi
      SNAP_SIZE=$(stat -c %s "$PRE_RESTORE_ARCHIVE")
      log_ok "Snapshot created: $PRE_RESTORE_ARCHIVE ($((SNAP_SIZE / 1024)) KB)"
    fi
  fi
fi

# ============================================================
# Phase 3 of 7: Fetch S3 archive
# ============================================================
log_step "Phase 3/7: Fetch S3 archive"

DOWNLOAD_PATH="/tmp/restore-source-${TIMESTAMP}.tar.gz"

if is_dry_run; then
  log_info "[DRY_RUN] would run: aws s3 cp s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY $DOWNLOAD_PATH"
else
  log_info "Downloading s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY"
  if ! aws s3 cp "s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY" "$DOWNLOAD_PATH" --quiet; then
    log_error "S3 download failed. Aborting."
    log_error "Pre-restore snapshot is still at: ${PRE_RESTORE_ARCHIVE:-<none>}"
    rm -f "$DOWNLOAD_PATH"
    exit 1
  fi
  DOWNLOAD_SIZE=$(stat -c %s "$DOWNLOAD_PATH")
  log_ok "Downloaded: $DOWNLOAD_PATH ($((DOWNLOAD_SIZE / 1024)) KB)"
fi

# ============================================================
# Phase 4 of 7: Extract to /
# ============================================================
log_step "Phase 4/7: Extract to /"

if is_dry_run; then
  log_info "[DRY_RUN] would run: tar -xzf $DOWNLOAD_PATH -C /"
  log_info "[DRY_RUN] would then run: rm -f $DOWNLOAD_PATH"
else
  # Exclude the BACKUP-MANIFEST.txt from extraction (it's inside the
  # archive as informational content, not something to write to /).
  if ! tar -xzf "$DOWNLOAD_PATH" --exclude=BACKUP-MANIFEST.txt -C /; then
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

  # Also print the manifest for context (audit/debugging)
  if MANIFEST=$(tar -xzf "$DOWNLOAD_PATH" -O BACKUP-MANIFEST.txt 2>/dev/null); then
    log_info "Backup manifest:"
    echo "$MANIFEST" | while IFS= read -r line; do
      log_info "  $line"
    done
  fi

  rm -f "$DOWNLOAD_PATH"
fi

# ============================================================
# Phase 5 of 7: Write credentials stubs (if missing)
# ============================================================
log_step "Phase 5/7: Write credentials stubs (deploy-host specific)"

if [ "$SKIP_CREDENTIALS_STUB" = "yes" ]; then
  log_warn "Skipping credentials stub creation (SKIP_CREDENTIALS_STUB=yes)"
elif is_dry_run; then
  log_info "[DRY_RUN] would create ~/.aws/credentials stubs where missing"
else
  # Content of the stub file. Clear and actionable so an operator who
  # gets a "profile not found" error immediately understands why.
  STUB_CONTENT="# ============================================================
# STUB FILE - real credentials NOT stored here.
# ============================================================
#
# The deploy-host backup/restore system DELIBERATELY EXCLUDES
# .aws/credentials from backup because it contains long-lived
# cross-account keys (typically for the ZoningInfoAdmin profile).
#
# If you see this file, real credentials were never restored to
# this instance. To use --profile ZoningInfoAdmin (or similar
# long-lived-key profiles), copy the corresponding [profile]
# block from your Mac's ~/.aws/credentials into this file.
#
# For sandbox-account operations, no credentials file is needed
# at all - the deploy-host EC2 instance role provides sandbox
# credentials automatically via IMDS.
#
# Related: ~/.aws/config in this instance already has the
# [profile ZI-Sandbox] block pointing at Ec2InstanceMetadata as
# its credential_source. That works without any keys.
# ============================================================
"

  for entry in "${CREDENTIALS_STUBS[@]}"; do
    IFS=':' read -r path owner group mode <<< "$entry"

    # Ensure parent dir exists
    parent=$(dirname "$path")
    if [ ! -d "$parent" ]; then
      install -d -o "$owner" -g "$group" -m 700 "$parent"
      log_info "  Created directory $parent (owned by $owner)"
    fi

    if [ ! -f "$path" ]; then
      printf '%s' "$STUB_CONTENT" > "$path"
      chown "$owner:$group" "$path"
      chmod "$mode" "$path"
      log_ok "  Wrote stub: $path (owner=$owner mode=$mode)"
    else
      log_info "  $path already exists - leaving alone"
    fi
  done
fi

# ============================================================
# Phase 6 of 7: Verify (spot-check known paths)
# ============================================================
log_step "Phase 6/7: Verify restoration"

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

  if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Critical paths missing after restore:"
    for m in "${MISSING[@]}"; do
      log_error "  $m"
    done
    log_error "To undo:"
    if [ -n "$PRE_RESTORE_ARCHIVE" ] && [ -f "$PRE_RESTORE_ARCHIVE" ]; then
      log_error "  sudo tar -xzf $PRE_RESTORE_ARCHIVE -C /"
    else
      log_error "  (no pre-restore snapshot - manual recovery needed)"
    fi
    exit 1
  fi
fi

# ============================================================
# Phase 7 of 7: Announce undo
# ============================================================
log_step "Phase 7/7: Announce undo path"

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
    log_warn "No pre-restore snapshot was taken. No undo path available."
  fi
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "restore-state (deploy-host) - DRY RUN complete (no changes made)"
  log_info "Would have restored ${#KNOWN_PATHS[@]} tracked path locations from"
  log_info "  s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY"
else
  log_step "restore-state (deploy-host) complete"
  log_ok "Deploy-host state restored from s3://$DEPLOY_HOST_BACKUPS_BUCKET/$RESTORE_KEY"
  log_info "If you need real cross-account credentials (ZoningInfoAdmin etc.),"
  log_info "copy the [profile] block from your Mac's ~/.aws/credentials"
  log_info "into /root/.aws/credentials or /home/ubuntu/.aws/credentials"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
