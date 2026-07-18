#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/db-delete-backup.sh
#
# Purpose:  Delete one or more logical-DB backups by INDEX (from
#           db-list-backups.sh output) or by full backup DB name.
#           Multiple selectors accepted — batch delete in one run.
#
# Usage:    sudo scripts/deploy-host/db-delete-backup.sh <env> <selector> [<selector> ...]
# Examples:
#   Delete backup #1 (as listed by db-list-backups):
#     sudo scripts/deploy-host/db-delete-backup.sh sandbox 1
#
#   Delete backups #1, #3, #5:
#     sudo scripts/deploy-host/db-delete-backup.sh sandbox 1 3 5
#
#   Delete by full name (skip the number lookup):
#     sudo scripts/deploy-host/db-delete-backup.sh sandbox drupal_backup_20260717_201352
#
#   Mix of indexes and names:
#     sudo scripts/deploy-host/db-delete-backup.sh sandbox 1 drupal_backup_20260717_201352
#
# Env:      DB=<prefix>  Override the default db name prefix (drupal)
#           CONFIRMED=yes  Skip interactive confirmation
#
# Safety:
#   - Refuses to delete anything that doesn't match `<prefix>_backup_%`.
#     Won't touch the live app DB.
#   - Numeric selectors are resolved against the CURRENT listing at run
#     time. If new backups appear between listing and deletion, indexes
#     may point to different rows — for single-operator use, this is
#     fine; if scripting, prefer full-name selectors.
#   - Interactive prompt shows every resolved DB name before dropping,
#     unless CONFIRMED=yes.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ] || [ $# -lt 2 ]; then
  cat >&2 <<HELP
Usage: $0 <env> <selector> [<selector> ...]
  <selector>  index number (from db-list-backups) OR full backup DB name
Examples:
  $0 sandbox 1                                    # delete #1
  $0 sandbox 1 3 5                                # delete #1, #3, #5
  $0 sandbox drupal_backup_20260717_201352        # delete by name
  DB=zinew $0 sandbox 1 2                         # non-default prefix
HELP
  exit 1
fi
shift

DB_PREFIX="${DB:-drupal}"

# Fetch current backup listing, ordered same as db-list-backups.
# Format: one line per backup, "index<TAB>name".
LISTING=$(psql-env "$ENV" -d postgres -tAF $'\t' <<SQL
SELECT ROW_NUMBER() OVER (ORDER BY datname DESC),
       datname
FROM pg_database
WHERE datname LIKE '${DB_PREFIX}_backup_%'
ORDER BY datname DESC;
SQL
)

if [ -z "$LISTING" ]; then
  echo "No backups matching '${DB_PREFIX}_backup_%' in env=$ENV." >&2
  exit 1
fi

# Resolve each selector to a full DB name.
declare -a TO_DELETE=()
for SEL in "$@"; do
  if [[ "$SEL" =~ ^[0-9]+$ ]]; then
    # Numeric — look up index in the listing
    NAME=$(printf '%s\n' "$LISTING" | awk -F'\t' -v n="$SEL" '$1==n {print $2}')
    if [ -z "$NAME" ]; then
      echo "ERROR: selector '$SEL' is out of range." >&2
      echo "       Current listing has $(printf '%s\n' "$LISTING" | wc -l | tr -d ' ') entries." >&2
      exit 1
    fi
    TO_DELETE+=("$NAME")
  else
    # Name — verify it exists AND matches the safety pattern
    if ! printf '%s\n' "$LISTING" | awk -F'\t' -v n="$SEL" '$2==n {found=1} END {exit !found}'; then
      echo "ERROR: '$SEL' is not in the '${DB_PREFIX}_backup_%' listing." >&2
      echo "       Refusing to touch DBs outside the backup pattern (safety)." >&2
      exit 1
    fi
    TO_DELETE+=("$SEL")
  fi
done

# Confirmation
echo "About to DROP the following backup databases in env=$ENV:" >&2
for NAME in "${TO_DELETE[@]}"; do
  echo "  - $NAME" >&2
done
echo "" >&2

if [ "${CONFIRMED:-}" != "yes" ]; then
  read -r -p "Type 'yes' to continue: " ANS
  if [ "$ANS" != "yes" ]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

# Execute DROPs. Each in its own psql invocation so a single failure
# doesn't halt the batch (we log each result individually).
FAILED=0
for NAME in "${TO_DELETE[@]}"; do
  echo "=== dropping $NAME ===" >&2
  if psql-env "$ENV" -d postgres -c "DROP DATABASE $NAME;" >&2; then
    echo "OK: dropped $NAME" >&2
  else
    echo "FAIL: could not drop $NAME (may have active connections)" >&2
    FAILED=$((FAILED + 1))
  fi
done

echo "" >&2
if [ "$FAILED" -eq 0 ]; then
  echo "All ${#TO_DELETE[@]} backup(s) deleted." >&2
else
  echo "Completed with $FAILED failure(s) out of ${#TO_DELETE[@]}." >&2
  exit 1
fi
