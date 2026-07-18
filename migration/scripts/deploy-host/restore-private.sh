#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/restore-private.sh
#
# Purpose:  Restore the Drupal PRIVATE files directory (/var/www/drupal-private)
#           from an S3-staged tarball onto sandbox FSx. Atomic swap:
#           extract fresh, rename current to .BAK.<UTC>, promote .NEW.
#
# Sibling of restore-files.sh — same 6-phase pattern, different target
# and defaults. Kept as a separate script (vs. one script with a mode
# flag) because the two targets have different sizing characteristics
# and slightly different validation logic.
#
# Flow (six phases, mirrors restore-files.sh):
#   1. Preconditions        (root, tools, /var/www mounted)
#   2. Confirmation
#   3. Fetch tarball        (reuses cached local file unless FORCE_DOWNLOAD=yes)
#   4. Extract to .NEW dir  (--strip-components=1 to drop "private/")
#   5. Ownership + perms    (root:www-data, u=rwX,g=rwX,o=)
#   6. Atomic swap          (rename current → .BAK, .NEW → current)
#
# On many Drupal sites the private/ dir is nearly empty (just an
# .htaccess deny-all). The size-validation is accordingly relaxed —
# we still require the file be a valid gzip archive but skip the
# "must be at least N MB" sanity check that would make sense for
# public files.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   S3 bucket holding the tarball  (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Object key                     (dumps/drupal-private.tar.gz)
#   DUMP_LOCAL_PATH    Local staging path             (/var/www/mysql/drupal-private.tar.gz)
#   TARGET_DIR         Where private files live       (/var/www/drupal-private)
#   KEEP_BAK           yes = keep .BAK on success     (yes)
#   FORCE_DOWNLOAD     yes = re-download from S3
#   CONFIRMED          yes = skip Y/N confirm
#   DRY_RUN            yes = preview commands
#
# Runs as:  root (via sudo). Same permissions as restore-files.sh.
#
# Logging:  /var/log/worxco-migration/restore-private-<UTC>.log locally
#           + s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-17

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/drupal-private.tar.gz}"
DUMP_LOCAL_PATH="${DUMP_LOCAL_PATH:-/var/www/mysql/drupal-private.tar.gz}"
TARGET_DIR="${TARGET_DIR:-/var/www/drupal-private}"
KEEP_BAK="${KEEP_BAK:-yes}"

log_init "restore-private"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

STAMP=$(date -u +%Y%m%d_%H%M%SZ)
NEW_DIR="${TARGET_DIR}.NEW.${STAMP}"
BAK_DIR="${TARGET_DIR}.BAK.${STAMP}"

log_step "restore-private — S3 tarball → FSx (atomic swap)"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "DUMP_S3_KEY      = $DUMP_S3_KEY"
log_info "DUMP_LOCAL_PATH  = $DUMP_LOCAL_PATH"
log_info "TARGET_DIR       = $TARGET_DIR"
log_info "STAMP            = $STAMP"
log_info "KEEP_BAK         = $KEEP_BAK"
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
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    exit 1
  fi
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

confirm_or_exit "About to REPLACE $TARGET_DIR with the contents of the S3 tarball.
    Source: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Current $TARGET_DIR: $CURRENT_SUMMARY
    New content will be extracted to $NEW_DIR, then atomically swapped.
    Current dir preserved as $BAK_DIR
    ($([ "$KEEP_BAK" = "yes" ] && echo "kept until manually deleted" || echo "auto-deleted on success"))."

# ============================================================
# Phase 3 of 6: Fetch tarball from S3
# ============================================================
log_step "Phase 3/6: Fetch tarball from S3"

DUMP_STAGING="$(dirname "$DUMP_LOCAL_PATH")"
if [ ! -d "$DUMP_STAGING" ]; then
  run_or_echo mkdir -p "$DUMP_STAGING"
fi

if [ -f "$DUMP_LOCAL_PATH" ] && [ "${FORCE_DOWNLOAD:-}" != "yes" ]; then
  SIZE_BYTES=$(stat -c %s "$DUMP_LOCAL_PATH" 2>/dev/null || echo 0)
  log_info "Reusing cached local tarball: $DUMP_LOCAL_PATH (${SIZE_BYTES} bytes)"
else
  log_info "Downloading s3://$MIGRATION_BUCKET/$DUMP_S3_KEY → $DUMP_LOCAL_PATH"
  if is_dry_run; then
    log_info "[DRY_RUN] would run: aws s3 cp s3://$MIGRATION_BUCKET/$DUMP_S3_KEY $DUMP_LOCAL_PATH"
  else
    aws s3 cp "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY" "$DUMP_LOCAL_PATH"
    SIZE_BYTES=$(stat -c %s "$DUMP_LOCAL_PATH")
    log_ok "Downloaded ${SIZE_BYTES} bytes"
  fi
fi

if ! is_dry_run; then
  if [ ! -s "$DUMP_LOCAL_PATH" ]; then
    log_error "Tarball is empty or missing: $DUMP_LOCAL_PATH"
    exit 1
  fi
  MAGIC=$(head -c 2 "$DUMP_LOCAL_PATH" | od -An -tx1 | tr -d ' ')
  if [ "$MAGIC" != "1f8b" ]; then
    log_error "Tarball doesn't look like a gzip file (magic bytes: $MAGIC, expected 1f8b)"
    exit 1
  fi
  log_ok "Tarball validated (gzip magic bytes present)"
fi

# ============================================================
# Phase 4 of 6: Extract to .NEW dir
# ============================================================
log_step "Phase 4/6: Extract tarball to $NEW_DIR"

if [ -e "$NEW_DIR" ]; then
  log_error "$NEW_DIR already exists (from an aborted prior run?)."
  log_info  "Remove it manually and retry: sudo rm -rf $NEW_DIR"
  exit 1
fi

if is_dry_run; then
  log_info "[DRY_RUN] would run: mkdir -p $NEW_DIR && tar xzf $DUMP_LOCAL_PATH -C $NEW_DIR --strip-components=1"
else
  mkdir -p "$NEW_DIR"
  # --strip-components=1 removes the top-level "private/" that
  # dump-private.sh creates via `tar czf - -C $DRUPAL_ROOT private`.
  tar xzf "$DUMP_LOCAL_PATH" -C "$NEW_DIR" --strip-components=1
  EXTRACT_COUNT=$(find "$NEW_DIR" -type f 2>/dev/null | wc -l)
  EXTRACT_SIZE=$(du -sh "$NEW_DIR" 2>/dev/null | cut -f1)
  log_ok "Extracted ${EXTRACT_COUNT} files (${EXTRACT_SIZE})"
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
# Phase 6 of 6: Atomic swap
# ============================================================
log_step "Phase 6/6: Atomic swap (current → BAK, NEW → current)"

if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  [ -d "$TARGET_DIR" ] && log_info "  mv $TARGET_DIR $BAK_DIR"
  log_info "  mv $NEW_DIR $TARGET_DIR"
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

  NEW_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
  NEW_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
  log_info "Restored $TARGET_DIR: $NEW_SIZE, $NEW_COUNT files"

  if [ -n "$BAK_DIR" ] && [ -d "$BAK_DIR" ] && [ "$KEEP_BAK" != "yes" ]; then
    log_info "KEEP_BAK=$KEEP_BAK — removing $BAK_DIR"
    rm -rf "$BAK_DIR"
    log_ok "Cleaned up $BAK_DIR"
  elif [ -n "$BAK_DIR" ]; then
    log_info "Previous private files preserved at: $BAK_DIR"
    log_info "Clean up when satisfied: sudo rm -rf $BAK_DIR"
  fi
fi

log_step "restore-private complete"
log_ok "$TARGET_DIR restored from s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
