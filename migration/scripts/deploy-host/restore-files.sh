#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/restore-files.sh
#
# Purpose:  Restore the PUBLIC user-uploads directory
#           (web/sites/default/files) from an S3-staged tarball onto
#           sandbox FSx. Atomic swap: extract fresh, rename current
#           to .BAK.<UTC>, promote .NEW → current. Site keeps serving
#           through the swap; the "cutover" is a single mv.
#
# Flow (six phases, mirrors restore-mysql.sh):
#   1. Preconditions        (root, tools, /var/www mounted, Drupal deployed)
#   2. Confirmation         (rename+swap is atomic but changes what visitors see)
#   3. Fetch tarball        (reuses cached local file unless FORCE_DOWNLOAD=yes)
#   4. Extract to .NEW dir  (--strip-components=1 to drop the top-level "files/")
#   5. Ownership + perms    (root:www-data, u=rwX,g=rwX,o=)
#   6. Atomic swap          (rename current → .BAK, .NEW → current)
#
# Idempotent:
#   - Safe to re-run: each run produces a distinct .NEW.<UTC> and .BAK.<UTC>
#   - Existing local tarball is reused unless FORCE_DOWNLOAD=yes
#   - If a prior aborted run left .NEW.<UTC> around, this run's timestamp
#     differs — no collision
#
# Backup policy:
#   - Previous files/ dir is preserved as .BAK.<UTC> (NOT auto-deleted).
#     Operator drops it manually when satisfied with the new state.
#   - KEEP_BAK=no forces auto-cleanup on success. Default: keep.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   S3 bucket holding the tarball  (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Object key in that bucket      (dumps/drupal-files.tar.gz)
#   DUMP_LOCAL_PATH    Local staging path             (/var/www/mysql/drupal-files.tar.gz)
#   TARGET_DIR         Where files live               (/var/www/drupal/web/sites/default/files)
#   KEEP_BAK           yes = keep .BAK on success     (yes)
#   FORCE_DOWNLOAD     yes = re-download from S3
#   CONFIRMED          yes = skip Y/N confirm
#   DRY_RUN            yes = preview commands
#
# Runs as:  root (via sudo). Needs FSx write access, S3 read via IAM
#           instance profile, and enough local FSx space for the tarball
#           + fresh extract + previous .BAK simultaneously (~2x the
#           files/ size worst case).
#
# Logging:  /var/log/worxco-migration/restore-files-<UTC>.log locally
#           + s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-17

set -euo pipefail

# Source the shared helper library (colors, logging, confirm, dry-run).
source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/drupal-files.tar.gz}"
DUMP_LOCAL_PATH="${DUMP_LOCAL_PATH:-/var/www/mysql/drupal-files.tar.gz}"
TARGET_DIR="${TARGET_DIR:-/var/www/drupal/web/sites/default/files}"
KEEP_BAK="${KEEP_BAK:-yes}"

# ============================================================
# Set up logging + on-exit S3 upload
# ============================================================
log_init "restore-files"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

STAMP=$(date -u +%Y%m%d_%H%M%SZ)
NEW_DIR="${TARGET_DIR}.NEW.${STAMP}"
BAK_DIR="${TARGET_DIR}.BAK.${STAMP}"

log_step "restore-files — S3 tarball → FSx (atomic swap)"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "DUMP_S3_KEY      = $DUMP_S3_KEY"
log_info "DUMP_LOCAL_PATH  = $DUMP_LOCAL_PATH"
log_info "TARGET_DIR       = $TARGET_DIR"
log_info "STAMP            = $STAMP"
log_info "NEW_DIR          = $NEW_DIR"
log_info "BAK_DIR          = $BAK_DIR"
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
  log_info  "Example: sudo -E ./restore-files.sh"
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
  log_error "/var/www is not mounted."
  log_info  "Run: sudo use-env sandbox"
  exit 1
fi
log_ok "/var/www is mounted (FSx)"

TARGET_PARENT="$(dirname "$TARGET_DIR")"
if [ ! -d "$TARGET_PARENT" ]; then
  log_error "Target parent directory does not exist: $TARGET_PARENT"
  log_info  "Is Drupal deployed at /var/www/drupal? Run make install-drupal ENV=sandbox first."
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
    New content will be extracted to $NEW_DIR, then atomically swapped
    into place. The current dir will be preserved as $BAK_DIR
    ($([ "$KEEP_BAK" = "yes" ] && echo "kept until manually deleted" || echo "auto-deleted on success"))."

# ============================================================
# Phase 3 of 6: Fetch tarball from S3
# ============================================================
log_step "Phase 3/6: Fetch tarball from S3"

DUMP_STAGING="$(dirname "$DUMP_LOCAL_PATH")"
if [ ! -d "$DUMP_STAGING" ]; then
  log_info "Creating staging dir: $DUMP_STAGING"
  run_or_echo mkdir -p "$DUMP_STAGING"
fi

if [ -f "$DUMP_LOCAL_PATH" ] && [ "${FORCE_DOWNLOAD:-}" != "yes" ]; then
  SIZE_MB=$(( $(stat -c %s "$DUMP_LOCAL_PATH" 2>/dev/null || echo 0) / 1024 / 1024 ))
  log_info "Reusing cached local tarball: $DUMP_LOCAL_PATH (${SIZE_MB} MB)"
  log_info "(Set FORCE_DOWNLOAD=yes to force re-download from S3)"
else
  if [ -f "$DUMP_LOCAL_PATH" ]; then
    log_info "FORCE_DOWNLOAD=yes — re-downloading despite existing local file"
  fi
  log_info "Downloading s3://$MIGRATION_BUCKET/$DUMP_S3_KEY → $DUMP_LOCAL_PATH"
  time_start=$SECONDS
  if is_dry_run; then
    log_info "[DRY_RUN] would run: aws s3 cp s3://$MIGRATION_BUCKET/$DUMP_S3_KEY $DUMP_LOCAL_PATH"
  else
    aws s3 cp "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY" "$DUMP_LOCAL_PATH"
    time_elapsed=$(( SECONDS - time_start ))
    SIZE_MB=$(( $(stat -c %s "$DUMP_LOCAL_PATH") / 1024 / 1024 ))
    log_ok "Downloaded ${SIZE_MB} MB in ${time_elapsed}s"
  fi
fi

if ! is_dry_run; then
  if [ ! -s "$DUMP_LOCAL_PATH" ]; then
    log_error "Tarball is empty or missing: $DUMP_LOCAL_PATH"
    exit 1
  fi
  # Verify it's a gzip-compressed file (first 2 bytes = 0x1f 0x8b)
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
  # --strip-components=1 removes the top-level "files/" directory that
  # dump-files.sh creates when it runs `tar czf - -C .../sites/default files`.
  # We want the CONTENTS of that files/ directory to land in $NEW_DIR.
  time_start=$SECONDS
  tar xzf "$DUMP_LOCAL_PATH" -C "$NEW_DIR" --strip-components=1
  time_elapsed=$(( SECONDS - time_start ))
  EXTRACT_SIZE=$(du -sh "$NEW_DIR" 2>/dev/null | cut -f1)
  EXTRACT_COUNT=$(find "$NEW_DIR" -type f 2>/dev/null | wc -l)
  log_ok "Extracted ${EXTRACT_COUNT} files (${EXTRACT_SIZE}) in ${time_elapsed}s"
fi

# ============================================================
# Phase 5 of 6: Ownership + permissions
# ============================================================
log_step "Phase 5/6: Set ownership + permissions"

# Match install-drupal.sh:481-489 pattern:
#   root:www-data ownership
#   u=rwX,g=rwX,o= (owner + group r/w + traverse; other locked out)
if is_dry_run; then
  log_info "[DRY_RUN] would run: chown -R root:www-data $NEW_DIR && chmod -R u=rwX,g=rwX,o= $NEW_DIR"
else
  chown -R root:www-data "$NEW_DIR"
  chmod -R u=rwX,g=rwX,o= "$NEW_DIR"
  log_ok "Ownership set to root:www-data; permissions u=rwX,g=rwX,o="
fi

# ============================================================
# Phase 6 of 6: Atomic swap + verify
# ============================================================
log_step "Phase 6/6: Atomic swap (current → BAK, NEW → current)"

if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  [ -d "$TARGET_DIR" ] && log_info "  mv $TARGET_DIR $BAK_DIR"
  log_info "  mv $NEW_DIR $TARGET_DIR"
else
  # If the target already exists, rename to BAK first. On a fresh
  # install-drupal, sites/default/files might be empty or missing entirely.
  if [ -d "$TARGET_DIR" ]; then
    mv "$TARGET_DIR" "$BAK_DIR"
    log_ok "Renamed current: $TARGET_DIR → $BAK_DIR"
  else
    log_info "No existing $TARGET_DIR to preserve; skipping BAK step"
    BAK_DIR=""
  fi

  mv "$NEW_DIR" "$TARGET_DIR"
  log_ok "Promoted: $NEW_DIR → $TARGET_DIR"

  # Verify
  NEW_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
  NEW_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
  log_info "Restored $TARGET_DIR: $NEW_SIZE, $NEW_COUNT files"

  # Cleanup BAK if configured
  if [ -n "$BAK_DIR" ] && [ -d "$BAK_DIR" ] && [ "$KEEP_BAK" != "yes" ]; then
    log_info "KEEP_BAK=$KEEP_BAK — removing $BAK_DIR"
    rm -rf "$BAK_DIR"
    log_ok "Cleaned up $BAK_DIR"
  elif [ -n "$BAK_DIR" ]; then
    log_info "Previous files preserved at: $BAK_DIR"
    log_info "Clean up when satisfied: sudo rm -rf $BAK_DIR"
  fi
fi

log_step "restore-files complete"
log_ok "$TARGET_DIR restored from s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
log_info "Recommend: make clear-drupal-cache ENV=sandbox (to invalidate image-style caches)"
