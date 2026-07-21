#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/restore-codebase.sh
#
# Purpose:  Restore prod's Drupal CODEBASE (composer install output +
#           custom modules/themes) from an S3-staged tarball onto
#           sandbox FSx. Atomic swap: extract fresh, rename current to
#           .BAK.<UTC>, promote .NEW → current. Preserves sandbox-managed
#           files across the swap (settings.php, .installed marker).
#
# Sibling of restore-files.sh / restore-private.sh — same 6-phase pattern.
#
# Flow:
#   1. Preconditions        (root, tools, /var/www mounted, Drupal target
#                            parent exists)
#   2. Confirmation
#   3. Fetch tarball        (reuses cached local file unless FORCE_DOWNLOAD=yes)
#   4. Extract to .NEW dir  (no --strip-components; dump-codebase.sh uses
#                            `tar czf - -C $DRUPAL_ROOT .` so tarball is
#                            files-directly, not wrapped in a top-level dir)
#   5. Ownership + perms    (root:www-data, u=rwX,g=rwX,o=)
#   6. Atomic swap          (rename current → .BAK, .NEW → current,
#                            then restore preserve-list files from .BAK)
#
# ** Codebase restore is UNUSUAL in practice. ** Most sandbox test cycles
# WANT sandbox to run newer or diverged code from prod (that's the point
# of a sandbox — test the changes not-yet-in-prod). Only reach for this
# when you deliberately want prod-parity in the code path too.
#
# Preserve-list (sandbox-managed, override the tarball):
#   web/sites/default/settings.php — env-var driven, written by
#     install-drupal.sh from a sandbox-specific template. Prod's
#     settings.php has PROD DB endpoints / secrets paths and would
#     immediately point sandbox at prod's RDS if not preserved.
#   .installed — deployment marker (see docs/memory/structural-checks-over-markers.md
#     — informational, no longer used as a gate). Preserved so
#     install-drupal's IF-EXISTS check stays consistent with sandbox
#     history rather than reflecting prod's install date.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   S3 bucket holding tarball  (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Object key                 (dumps/drupal-codebase.tar.gz)
#   DUMP_LOCAL_PATH    Local staging path         (/var/www/mysql/drupal-codebase.tar.gz)
#   TARGET_DIR         Where codebase lives       (/var/www/drupal)
#   PRESERVE_FROM_BAK  Space-separated repo-relative paths to copy from
#                       .BAK back into new dir after swap
#                       (default: "web/sites/default/settings.php .installed")
#   KEEP_BAK           yes = keep .BAK on success (yes)
#   FORCE_DOWNLOAD     yes = re-download from S3
#   CONFIRMED          yes = skip Y/N confirm
#   DRY_RUN            yes = preview commands
#
# Runs as:  root (via sudo). FSx write, S3 read via IAM instance role.
#
# Logging:  /var/log/worxco-migration/restore-codebase-<UTC>.log locally
#           + s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-20

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/drupal-codebase.tar.gz}"
DUMP_LOCAL_PATH="${DUMP_LOCAL_PATH:-/var/www/mysql/drupal-codebase.tar.gz}"
TARGET_DIR="${TARGET_DIR:-/var/www/drupal}"
KEEP_BAK="${KEEP_BAK:-yes}"
PRESERVE_FROM_BAK="${PRESERVE_FROM_BAK:-web/sites/default/settings.php .installed}"

log_init "restore-codebase"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

STAMP=$(date -u +%Y%m%d_%H%M%SZ)
NEW_DIR="${TARGET_DIR}.NEW.${STAMP}"
BAK_DIR="${TARGET_DIR}.BAK.${STAMP}"

log_step "restore-codebase — S3 tarball → FSx (atomic swap, preserves sandbox files)"
log_info "MIGRATION_BUCKET  = $MIGRATION_BUCKET"
log_info "DUMP_S3_KEY       = $DUMP_S3_KEY"
log_info "DUMP_LOCAL_PATH   = $DUMP_LOCAL_PATH"
log_info "TARGET_DIR        = $TARGET_DIR"
log_info "STAMP             = $STAMP"
log_info "KEEP_BAK          = $KEEP_BAK"
log_info "PRESERVE_FROM_BAK = $PRESERVE_FROM_BAK"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root (use sudo)."
  exit 1
fi

for tool in tar aws stat find; do
  command -v "$tool" >/dev/null 2>&1 \
    || { log_error "Required tool '$tool' not found on PATH."; exit 1; }
done
log_ok "All required tools available"

if ! mountpoint -q /var/www 2>/dev/null; then
  log_error "/var/www is not mounted. Run: sudo use-env sandbox"
  exit 1
fi
log_ok "/var/www is mounted (FSx)"

TARGET_PARENT="$(dirname "$TARGET_DIR")"
if [ ! -d "$TARGET_PARENT" ]; then
  log_error "Target parent directory does not exist: $TARGET_PARENT"
  exit 1
fi
log_ok "Target parent exists: $TARGET_PARENT"

# ============================================================
# Phase 2 of 6: Confirmation
# ============================================================
log_step "Phase 2/6: Confirmation"

CURRENT_SUMMARY="(not present)"
if [ -d "$TARGET_DIR" ]; then
  CURRENT_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
  CURRENT_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
  CURRENT_SUMMARY="$CURRENT_SIZE, $CURRENT_COUNT files"
fi

confirm_or_exit "About to REPLACE $TARGET_DIR (Drupal codebase) with the S3 tarball.
    Source: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Current $TARGET_DIR: $CURRENT_SUMMARY
    Sandbox-specific files WILL BE PRESERVED across the swap:
      $PRESERVE_FROM_BAK
    Rest of the tree becomes prod's (composer.json/lock, web/modules/, etc.).
    Previous state preserved as $BAK_DIR
    ($([ "$KEEP_BAK" = "yes" ] && echo "kept until manually deleted" || echo "auto-deleted on success"))."

# ============================================================
# Phase 3 of 6: Fetch tarball from S3
# ============================================================
log_step "Phase 3/6: Fetch tarball from S3"

DUMP_STAGING="$(dirname "$DUMP_LOCAL_PATH")"
[ ! -d "$DUMP_STAGING" ] && run_or_echo mkdir -p "$DUMP_STAGING"

if [ -f "$DUMP_LOCAL_PATH" ] && [ "${FORCE_DOWNLOAD:-}" != "yes" ]; then
  SIZE_MB=$(( $(stat -c %s "$DUMP_LOCAL_PATH" 2>/dev/null || echo 0) / 1024 / 1024 ))
  log_info "Reusing cached local tarball: $DUMP_LOCAL_PATH (${SIZE_MB} MB)"
  log_info "(Set FORCE_DOWNLOAD=yes to force re-download from S3)"
else
  [ -f "$DUMP_LOCAL_PATH" ] && log_info "FORCE_DOWNLOAD=yes — re-downloading"
  log_info "Downloading s3://$MIGRATION_BUCKET/$DUMP_S3_KEY → $DUMP_LOCAL_PATH"
  time_start=$SECONDS
  if is_dry_run; then
    log_info "[DRY_RUN] would run: aws s3 cp s3://$MIGRATION_BUCKET/$DUMP_S3_KEY $DUMP_LOCAL_PATH"
  else
    aws s3 cp "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY" "$DUMP_LOCAL_PATH"
    SIZE_MB=$(( $(stat -c %s "$DUMP_LOCAL_PATH") / 1024 / 1024 ))
    log_ok "Downloaded ${SIZE_MB} MB in $(( SECONDS - time_start ))s"
  fi
fi

if ! is_dry_run; then
  if [ ! -s "$DUMP_LOCAL_PATH" ]; then
    log_error "Tarball is empty or missing: $DUMP_LOCAL_PATH"
    exit 1
  fi
  MAGIC=$(head -c 2 "$DUMP_LOCAL_PATH" | od -An -tx1 | tr -d ' ')
  if [ "$MAGIC" != "1f8b" ]; then
    log_error "Tarball not gzip (magic $MAGIC, expected 1f8b)"
    exit 1
  fi
  log_ok "Tarball validated (gzip magic bytes present)"
fi

# ============================================================
# Phase 4 of 6: Extract to .NEW dir
# ============================================================
log_step "Phase 4/6: Extract tarball to $NEW_DIR"

if [ -e "$NEW_DIR" ]; then
  log_error "$NEW_DIR already exists (aborted prior run?). Remove and retry."
  exit 1
fi

if is_dry_run; then
  log_info "[DRY_RUN] would run: mkdir -p $NEW_DIR && tar xzf $DUMP_LOCAL_PATH -C $NEW_DIR"
else
  mkdir -p "$NEW_DIR"
  # dump-codebase.sh uses `tar czf - -C $DRUPAL_ROOT .` — the leading `.`
  # means the archive members are relative (`./composer.json`, `./web/...`)
  # without a wrapping top-level directory. So no --strip-components here
  # (unlike restore-files.sh / restore-private.sh which do strip a wrapper).
  time_start=$SECONDS
  tar xzf "$DUMP_LOCAL_PATH" -C "$NEW_DIR"
  EXTRACT_COUNT=$(find "$NEW_DIR" -type f 2>/dev/null | wc -l)
  EXTRACT_SIZE=$(du -sh "$NEW_DIR" 2>/dev/null | cut -f1)
  log_ok "Extracted ${EXTRACT_COUNT} files (${EXTRACT_SIZE}) in $(( SECONDS - time_start ))s"
fi

# ============================================================
# Phase 5 of 6: Ownership + permissions
# ============================================================
log_step "Phase 5/6: Set ownership + permissions"

if is_dry_run; then
  log_info "[DRY_RUN] would run: chown -R root:www-data $NEW_DIR && chmod -R u=rwX,g=rwX,o= $NEW_DIR"
else
  chown -R root:www-data "$NEW_DIR"
  chmod -R u=rwX,g=rwX,o= "$NEW_DIR"
  log_ok "Ownership set to root:www-data; permissions u=rwX,g=rwX,o="
fi

# ============================================================
# Phase 6 of 6: Atomic swap + preserve sandbox files
# ============================================================
log_step "Phase 6/6: Atomic swap (current → BAK, NEW → current)"

if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  [ -d "$TARGET_DIR" ] && log_info "  mv $TARGET_DIR $BAK_DIR"
  log_info "  mv $NEW_DIR $TARGET_DIR"
  log_info "  for f in $PRESERVE_FROM_BAK: cp -p $BAK_DIR/f $TARGET_DIR/f"
else
  if [ -d "$TARGET_DIR" ]; then
    mv "$TARGET_DIR" "$BAK_DIR"
    log_ok "Renamed current: $TARGET_DIR → $BAK_DIR"
  else
    log_info "No existing $TARGET_DIR to preserve; skipping BAK step"
    BAK_DIR=""
  fi

  mv "$NEW_DIR" "$TARGET_DIR"
  log_ok "Promoted: $NEW_DIR → $TARGET_DIR"

  # Preserve sandbox-managed files across the swap. See header + also
  # migration/scripts/deploy-host/restore-private.sh for the same
  # pattern applied to hash_salt.
  if [ -n "$BAK_DIR" ] && [ -d "$BAK_DIR" ] && [ -n "$PRESERVE_FROM_BAK" ]; then
    for f in $PRESERVE_FROM_BAK; do
      if [ -f "$BAK_DIR/$f" ]; then
        # Ensure the destination parent directory exists — the extracted
        # tarball SHOULD have provided it (settings.php's parent is a
        # standard Drupal path), but belt-and-suspenders.
        mkdir -p "$(dirname "$TARGET_DIR/$f")"
        cp -p "$BAK_DIR/$f" "$TARGET_DIR/$f"
        chown root:www-data "$TARGET_DIR/$f"
        log_ok "Preserved sandbox file across swap: $f"
      else
        log_warn "$f not in $BAK_DIR — nothing to preserve"
      fi
    done
  fi

  NEW_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
  NEW_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
  log_info "Restored $TARGET_DIR: $NEW_SIZE, $NEW_COUNT files"

  if [ -n "$BAK_DIR" ] && [ -d "$BAK_DIR" ] && [ "$KEEP_BAK" != "yes" ]; then
    log_info "KEEP_BAK=$KEEP_BAK — removing $BAK_DIR"
    rm -rf "$BAK_DIR"
    log_ok "Cleaned up $BAK_DIR"
  elif [ -n "$BAK_DIR" ]; then
    log_info "Previous codebase preserved at: $BAK_DIR"
    log_info "Clean up when satisfied: sudo rm -rf $BAK_DIR"
  fi
fi

log_step "restore-codebase complete"
log_ok "$TARGET_DIR restored from s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
log_info "Recommend: 'sudo -E vendor/bin/drush cr' (rebuild container against new code)"
log_info "           make clear-drupal-cache ENV=<env> (invalidate Valkey + PHP compiled)"
