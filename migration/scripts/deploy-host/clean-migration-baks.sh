#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# migration/scripts/deploy-host/clean-migration-baks.sh
#
# Purpose: Prune the accumulated safety-backup and staging directories
# that migration/restore scripts leave on FSx. Each restore-* operation
# does an atomic-swap that renames the current dir to <name>.BAK.<STAMP>
# and promotes a new copy from S3. With KEEP_BAK=yes (the default), those
# .BAK dirs stay forever — great for one-restore rollback, but they add
# up over time. This script surfaces + optionally deletes:
#
#   /var/www/*.BAK.<STAMP>            (safety backups from restore ops)
#   /var/www/*.NEW.<STAMP>            (aborted mid-swap detritus)
#   /var/www/*.RESTORE-STAGING.<STAMP> (aborted-extract detritus)
#
# Usage (from the deploy-host):
#   sudo bash migration/scripts/deploy-host/clean-migration-baks.sh              # dry-run
#   sudo bash migration/scripts/deploy-host/clean-migration-baks.sh CONFIRMED=yes  # delete
#
# Usage (from Mac):
#   make clean-migration-baks               # dry-run via SSM
#   make clean-migration-baks CONFIRMED=yes # delete via SSM
#
# Runs as: root (sudo). Only touches /var/www/ (FSx mount). Never
# touches /var/www/drupal itself (that's the LIVE codebase), only its
# .BAK/.NEW siblings.
#
# Safe by default: without CONFIRMED=yes, this is a pure listing.
# Exit codes: 0 = success (or nothing to clean), non-zero = permissions
# or unexpected state.
#
# Created: 2026-07-29

set -euo pipefail

# Accept CONFIRMED as an env var (make/SSM path) or as a bare positional
# arg (`sudo bash …clean-migration-baks.sh CONFIRMED=yes`).
CONFIRMED="${CONFIRMED:-}"
for arg in "$@"; do
  case "$arg" in
    CONFIRMED=*) CONFIRMED="${arg#CONFIRMED=}" ;;
  esac
done

FSX_ROOT="/var/www"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (use sudo). FSx paths are root-owned." >&2
  exit 1
fi

# Enumerate candidates. Include hidden entries (.RESTORE-STAGING.*) via
# a separate glob — bash's default * doesn't match leading-dot names.
shopt -s nullglob
CANDIDATES=(
  "$FSX_ROOT"/*.BAK.*
  "$FSX_ROOT"/*.NEW.*
  "$FSX_ROOT"/.RESTORE-STAGING.*
)
shopt -u nullglob

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No migration BAK / NEW / RESTORE-STAGING dirs under $FSX_ROOT/."
  echo "Nothing to clean."
  exit 0
fi

# Show what we found
echo "=== Candidates under $FSX_ROOT/ ==="
printf '  %-6s %-12s %s\n' 'SIZE' 'AGE' 'PATH'
TOTAL_KB=0
NOW_EPOCH=$(date +%s)
for c in "${CANDIDATES[@]}"; do
  [ -e "$c" ] || continue
  # du -sk yields KB; sum for grand total. cut -f1 grabs just the size.
  SZ_KB=$(du -sk "$c" 2>/dev/null | cut -f1)
  SZ_HR=$(du -sh "$c" 2>/dev/null | cut -f1)
  TOTAL_KB=$(( TOTAL_KB + ${SZ_KB:-0} ))

  # Age: seconds since mtime, formatted as "Nd" (or "N.Nh" if <24h)
  MTIME=$(stat -c %Y "$c" 2>/dev/null || echo "$NOW_EPOCH")
  AGE_SEC=$(( NOW_EPOCH - MTIME ))
  if [ "$AGE_SEC" -lt 3600 ]; then
    AGE_HR="${AGE_SEC}s"
  elif [ "$AGE_SEC" -lt 86400 ]; then
    AGE_HR="$(( AGE_SEC / 3600 ))h"
  else
    AGE_HR="$(( AGE_SEC / 86400 ))d"
  fi

  printf '  %-6s %-12s %s\n' "$SZ_HR" "$AGE_HR" "$c"
done

# Grand total (human-readable)
TOTAL_MB=$(( TOTAL_KB / 1024 ))
TOTAL_GB=$(( TOTAL_MB / 1024 ))
if [ "$TOTAL_GB" -gt "0" ]; then
  TOTAL_HR="${TOTAL_GB}.$(( (TOTAL_MB % 1024) / 100 ))G"
else
  TOTAL_HR="${TOTAL_MB}M"
fi

echo ""
echo "Total: ${#CANDIDATES[@]} dir(s), $TOTAL_HR"

if [ "$CONFIRMED" != "yes" ]; then
  echo ""
  echo "(Dry-run — no deletion performed.)"
  echo "To actually delete: re-run with CONFIRMED=yes"
  echo "  sudo bash $0 CONFIRMED=yes"
  echo "  or:  make clean-migration-baks CONFIRMED=yes"
  exit 0
fi

# CONFIRMED=yes — do the deletion.
echo ""
echo "=== Deleting (CONFIRMED=yes) ==="
FAILED=0
for c in "${CANDIDATES[@]}"; do
  [ -e "$c" ] || continue
  if rm -rf "$c"; then
    echo "  rm  $c"
  else
    echo "  FAIL $c" >&2
    FAILED=$(( FAILED + 1 ))
  fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "Cleaned $TOTAL_HR across ${#CANDIDATES[@]} dir(s)."
else
  echo "Cleaned with $FAILED failure(s). Inspect above."
  exit 1
fi
