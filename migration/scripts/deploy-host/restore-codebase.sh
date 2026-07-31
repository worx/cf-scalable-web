#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/restore-codebase.sh
#
# Purpose:  Restore prod's Drupal CODEBASE — Drupal root AND any custom
#           composer path-repository sibling packages (e.g.
#           `entity_bundle_manager`, `filtered_entity_reference`) — from
#           an S3-staged tarball onto sandbox FSx. Each top-level package
#           gets its own atomic swap; the Drupal root additionally
#           preserves sandbox-managed files (settings.php, .installed).
#
# Sibling of restore-files.sh / restore-private.sh, same phase-based
# pattern but with an extra iteration layer over the tarball's top-level
# directories.
#
# Flow:
#   1. Preconditions        (root, tools, /var/www mounted, target parent
#                            exists)
#   2. Confirmation
#   3. Fetch tarball        (reuses cached local file unless FORCE_DOWNLOAD=yes)
#   4. Extract to STAGING   Tarball produced by dump-codebase.sh contains
#                           multiple top-level dirs — the Drupal root plus
#                           any discovered composer path-repository
#                           siblings. We extract them all into a staging
#                           dir, then handle each independently.
#                           BACKWARD COMPAT: also handles legacy tarballs
#                           whose contents are directly at the tar root
#                           (composer.json at staging root) — treated as
#                           "Drupal root only, no siblings."
#   5. Per top-level dir:
#      a. Ownership + perms (root:www-data, u=rwX,g=rwX,o=)
#      b. Atomic swap into place (current → .BAK, .NEW → current)
#      c. If this dir is the Drupal root, apply PRESERVE_FROM_BAK
#   6. Cleanup staging + report
#
# ** Codebase restore is UNUSUAL in practice. ** Most sandbox test cycles
# WANT sandbox to run newer or diverged code from prod (that's the point
# of a sandbox — test the changes not-yet-in-prod). Only reach for this
# when you deliberately want prod-parity in the code path too.
#
# Identifying the Drupal root inside the staging tree:
#   Heuristic: the top-level directory that contains a `composer.json` file.
#   Any other top-level directory is treated as a sibling package.
#   If zero contain composer.json → error (malformed tarball).
#   If more than one contain composer.json → error (ambiguous).
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
#   TARGET_DIR         Where Drupal root lives    (/var/www/drupal)
#                      Siblings go to $(dirname TARGET_DIR)/${sibling_name}.
#   PRESERVE_FROM_BAK  Space-separated repo-relative paths to copy from
#                       .BAK back into new Drupal root after swap
#                       (default: "web/sites/default/settings.php .installed")
#                       Only applies to Drupal root, not siblings.
#   KEEP_BAK           yes = keep .BAK dirs on success (yes)
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
# Updated:  2026-07-28 — support multi-top-level tarballs for composer
#                        path-repository siblings

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
# STAGING_DIR: extracted tarball contents (potentially multiple top-level
# dirs — Drupal root + siblings). Cleaned up on success.
STAGING_DIR="$(dirname "$TARGET_DIR")/.RESTORE-STAGING.${STAMP}"
# Per-target NEW/BAK paths are computed inside Phase 5's loop.

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

for tool in tar aws stat find jq; do
  command -v "$tool" >/dev/null 2>&1 \
    || { log_error "Required tool '$tool' not found on PATH. Install: sudo apt install -y $tool"; exit 1; }
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
    Sibling packages in the tarball (composer path-repository targets)
    will land at \$(dirname $TARGET_DIR)/<sibling_name> — each with the
    same atomic-swap treatment as $TARGET_DIR itself.
    Previous state of each top-level dir preserved as <dir>.BAK.${STAMP}
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
# Phase 4 of 6: Extract tarball into a staging directory
# ============================================================
log_step "Phase 4/6: Extract tarball to $STAGING_DIR"

if [ -e "$STAGING_DIR" ]; then
  log_error "$STAGING_DIR already exists (aborted prior run?). Remove and retry."
  exit 1
fi

if is_dry_run; then
  log_info "[DRY_RUN] would run: mkdir -p $STAGING_DIR && tar xzf $DUMP_LOCAL_PATH -C $STAGING_DIR"
else
  mkdir -p "$STAGING_DIR"
  time_start=$SECONDS
  tar xzf "$DUMP_LOCAL_PATH" -C "$STAGING_DIR"
  EXTRACT_COUNT=$(find "$STAGING_DIR" -type f 2>/dev/null | wc -l)
  EXTRACT_SIZE=$(du -sh "$STAGING_DIR" 2>/dev/null | cut -f1)
  log_ok "Extracted ${EXTRACT_COUNT} files (${EXTRACT_SIZE}) in $(( SECONDS - time_start ))s"
fi

# Detect tarball layout: is composer.json at the staging root (legacy
# "bare" format), or at exactly one subdir (new "multi-top-level" format
# with siblings)?
if is_dry_run; then
  log_info "[DRY_RUN] skipping tarball layout detection"
  # Dry-run: pretend it's the legacy layout so we still print reasonable output.
  TOP_LEVEL_DIRS=""
  DRUPAL_STAGING_PATH="$STAGING_DIR"
  SIBLING_STAGING_PATHS=""
else
  # Enumerate top-level dirs (bare filenames, one per line)
  TOP_LEVEL_DIRS=$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

  if [ -f "$STAGING_DIR/composer.json" ]; then
    # Legacy tarball: contents directly at staging root, no siblings.
    log_info "Legacy tarball detected (composer.json at staging root, no siblings)"
    DRUPAL_STAGING_PATH="$STAGING_DIR"
    SIBLING_STAGING_PATHS=""
  else
    # New format: find the top-level dir whose composer.json declares
    # `"type": "project"`. Every composer package (including sibling
    # drupal-custom-module packages) has a composer.json, so mere
    # presence isn't a distinguisher. The composer package type IS —
    # only project-level composer.json uses "project"; module packages
    # use "drupal-module" / "drupal-custom-module" / etc.
    DRUPAL_CANDIDATES=""
    for d in $TOP_LEVEL_DIRS; do
      CJ="$STAGING_DIR/$d/composer.json"
      [ -f "$CJ" ] || continue
      TYPE=$(jq -r '.type // ""' "$CJ" 2>/dev/null || echo "")
      if [ "$TYPE" = "project" ]; then
        DRUPAL_CANDIDATES="$DRUPAL_CANDIDATES $d"
      fi
    done
    DRUPAL_CANDIDATES="${DRUPAL_CANDIDATES# }"
    N=$(echo $DRUPAL_CANDIDATES | wc -w)
    if [ "$N" = "0" ]; then
      log_error "No top-level dir in the tarball has composer.json type=project."
      log_error "Cannot identify the Drupal root. Malformed tarball?"
      log_error "Top-level dirs found: $TOP_LEVEL_DIRS"
      log_error "Staging kept at $STAGING_DIR for inspection."
      log_error "  Cleanup:  sudo rm -rf $STAGING_DIR"
      exit 1
    elif [ "$N" -gt "1" ]; then
      log_error "Multiple top-level dirs declare composer.json type=project:$(echo " $DRUPAL_CANDIDATES")"
      log_error "Ambiguous — cannot pick a single Drupal root."
      log_error "Staging kept at $STAGING_DIR for inspection."
      log_error "  Cleanup:  sudo rm -rf $STAGING_DIR"
      exit 1
    fi
    DRUPAL_STAGING_NAME=$(echo $DRUPAL_CANDIDATES | tr -d ' ')
    DRUPAL_STAGING_PATH="$STAGING_DIR/$DRUPAL_STAGING_NAME"
    SIBLING_STAGING_PATHS=""
    for d in $TOP_LEVEL_DIRS; do
      [ "$d" = "$DRUPAL_STAGING_NAME" ] && continue
      SIBLING_STAGING_PATHS="$SIBLING_STAGING_PATHS $d"
    done
    SIBLING_STAGING_PATHS="${SIBLING_STAGING_PATHS# }"
    log_ok "Drupal root:  $DRUPAL_STAGING_NAME  (from $STAGING_DIR)"
    if [ -n "$SIBLING_STAGING_PATHS" ]; then
      log_ok "Sibling(s):   $SIBLING_STAGING_PATHS"
    else
      log_info "No sibling packages in tarball"
    fi
  fi
fi

# ============================================================
# Phase 5 of 6: Per top-level dir — chown, atomic swap, preserve
# ============================================================
log_step "Phase 5/6: Swap each top-level dir into place"

TARGET_PARENT="$(dirname "$TARGET_DIR")"

# Helper: swap a single staging path → its final target atomically.
# Args: $1 = staging source path, $2 = target final path, $3 = "drupal" | "sibling"
swap_one() {
  local SRC="$1"
  local DST="$2"
  local KIND="$3"
  local NEW="${DST}.NEW.${STAMP}"
  local BAK="${DST}.BAK.${STAMP}"

  if is_dry_run; then
    log_info "[DRY_RUN] would swap $KIND: $SRC → $DST (via $NEW; existing → $BAK)"
    return 0
  fi

  # Move staging → .NEW. Both are on FSx so this is a metadata-only rename.
  mv "$SRC" "$NEW"
  chown -R root:www-data "$NEW"
  chmod -R u=rwX,g=rwX,o= "$NEW"

  # Atomic swap
  if [ -d "$DST" ]; then
    mv "$DST" "$BAK"
    log_ok "  $KIND: renamed current → $BAK"
  else
    log_info "  $KIND: no existing $DST to preserve; skipping BAK step"
    BAK=""
  fi
  mv "$NEW" "$DST"
  log_ok "  $KIND: promoted → $DST"

  # Only the Drupal root gets the preserve-list treatment.
  if [ "$KIND" = "drupal" ] && [ -n "$BAK" ] && [ -d "$BAK" ] && [ -n "$PRESERVE_FROM_BAK" ]; then
    for f in $PRESERVE_FROM_BAK; do
      if [ -f "$BAK/$f" ]; then
        mkdir -p "$(dirname "$DST/$f")"
        cp -p "$BAK/$f" "$DST/$f"
        chown root:www-data "$DST/$f"
        log_ok "  drupal: preserved sandbox file across swap: $f"
      else
        log_warn "  drupal: $f not in $BAK — nothing to preserve"
      fi
    done
  fi

  if [ -n "$BAK" ] && [ -d "$BAK" ] && [ "$KEEP_BAK" != "yes" ]; then
    log_info "  $KIND: KEEP_BAK=$KEEP_BAK — removing $BAK"
    rm -rf "$BAK"
  elif [ -n "$BAK" ]; then
    log_info "  $KIND: previous $DST preserved at $BAK (rm -rf $BAK when satisfied)"
  fi
}

# 1) Swap the Drupal root into $TARGET_DIR
swap_one "$DRUPAL_STAGING_PATH" "$TARGET_DIR" "drupal"

# 2) Swap each sibling into $(dirname TARGET_DIR)/${sibling_name}
if [ -n "$SIBLING_STAGING_PATHS" ]; then
  for sib in $SIBLING_STAGING_PATHS; do
    swap_one "$STAGING_DIR/$sib" "$TARGET_PARENT/$sib" "sibling"
  done
fi

# ============================================================
# Phase 6 of 6: Cleanup staging + report
# ============================================================
log_step "Phase 6/6: Cleanup staging + report"

if is_dry_run; then
  log_info "[DRY_RUN] would run: rm -rf $STAGING_DIR"
else
  # Staging should now be empty (all its top-level dirs were mv'd out).
  # Remove it even if not empty (belt-and-suspenders; unusual layouts).
  if [ -d "$STAGING_DIR" ]; then
    REMAINING=$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | wc -l)
    if [ "$REMAINING" -gt "0" ]; then
      log_warn "Staging dir has $REMAINING unexpected leftovers — inspect $STAGING_DIR before removing"
    else
      rmdir "$STAGING_DIR"
      log_ok "Removed empty staging dir"
    fi
  fi

  NEW_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
  NEW_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
  log_info "Restored $TARGET_DIR: $NEW_SIZE, $NEW_COUNT files"
fi

log_step "restore-codebase complete"
log_ok "$TARGET_DIR restored from s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
if [ -n "$SIBLING_STAGING_PATHS" ]; then
  log_ok "Sibling packages also restored:$(echo " $SIBLING_STAGING_PATHS")"
fi

# ============================================================
# MANDATORY next steps — DO NOT SKIP.
# ============================================================
# We just replaced vendor/ and web/ on FSx. But every PHP-FPM worker
# on every compute box still holds pre-swap bytecode in OPcache. If
# a request lands before OPcache is busted, PHP-FPM will:
#   (1) execute cached bytecode from files that no longer exist on disk;
#   (2) resolve class names against the NEW composer classmap on the
#       fresh vendor tree; and
#   (3) fatal-error when the old bytecode references classes the new
#       classmap doesn't have (e.g. Drupal 11.3.13's DrupalRuntime
#       when prod's tarball uses classic bootstrap).
#
# clear-drupal-cache alone is NOT sufficient — it only touches the
# FSx compiled-container dir + cache_* tables. It does NOT invalidate
# per-worker OPcache. restart-php-fpm is the only thing that does.
#
# migrate-full-all sequences the restart automatically as Phase 9.
# If you ran restore-codebase standalone, run these two, in order:
echo ""
echo "  ================================================================"
echo "  WARNING: PHP-FPM OPcache is now STALE. Every request will 500"
echo "  ================================================================"
echo "  Required follow-up (in order, from the operator's Mac):"
echo ""
echo "    make clear-drupal-cache ENV=<env>   # from repo root"
echo "    make restart-php-fpm ENV=<env>      # from repo root  <-- MANDATORY"
echo ""
echo "  (migrate-full-all does both automatically as Phases 8 and 9.)"
echo "  ================================================================"
echo ""
