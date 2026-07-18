#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/db-restore.sh
#
# Purpose:  Rollback via logical-DB rename (see
#           docs/memory/db-rollback-pattern.md). Complement to
#           db-backup.sh:
#             1. Drop current <target_db> (empty or otherwise)
#             2. Rename <source_backup_db> → <target_db>
#           Metadata-only, sub-second, application-transparent once
#           the app reconnects.
#
# Usage:    sudo scripts/deploy-host/db-restore.sh <env> <source_backup_db> [target_db]
# Example:  sudo scripts/deploy-host/db-restore.sh sandbox drupal_backup_20260717_201352
#           sudo scripts/deploy-host/db-restore.sh sandbox drupal_backup_20260717_201352 drupal
#
# Preconditions:
#   - /etc/worxco/envs/<env> readable (for DRUPAL_DB_USER)
#   - psql-env <env> works
#   - <source_backup_db> exists
#   - <target_db> exists (usually the current live DB you want to
#     replace; the DROP is destructive)
#   - CONFIRMED=yes in env, or interactive TTY for prompt
#
# Application impact:
#   - App using <target_db> will error briefly during the rename. If
#     this is a live app, put it in maintenance mode FIRST.

set -euo pipefail

ENV="${1:-}"
SOURCE_DB="${2:-}"
TARGET_DB="${3:-drupal}"

if [ -z "$ENV" ] || [ -z "$SOURCE_DB" ]; then
  echo "Usage: $0 <env> <source_backup_db> [target_db]" >&2
  echo "Example: $0 sandbox drupal_backup_20260717_201352" >&2
  echo "         (target defaults to 'drupal')" >&2
  echo "Hint: list existing backups via db-list-backups.sh $ENV" >&2
  exit 1
fi

ENV_FILE="/etc/worxco/envs/$ENV"
if [ ! -r "$ENV_FILE" ]; then
  echo "ERROR: env file not readable: $ENV_FILE" >&2
  echo "Run: sudo refresh-env-config $ENV" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

APP_USER="${DRUPAL_DB_USER:-}"
if [ -z "$APP_USER" ]; then
  echo "ERROR: DRUPAL_DB_USER not set after sourcing $ENV_FILE" >&2
  exit 1
fi

# Verify source backup exists
if ! psql-env "$ENV" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$SOURCE_DB'" | grep -q '^1$'; then
  echo "ERROR: source backup database '$SOURCE_DB' does not exist in env=$ENV" >&2
  echo "Hint: list existing backups via db-list-backups.sh $ENV" >&2
  exit 1
fi

# Verify target exists (we're going to drop it)
if ! psql-env "$ENV" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$TARGET_DB'" | grep -q '^1$'; then
  echo "ERROR: target database '$TARGET_DB' does not exist in env=$ENV" >&2
  echo "       (db-restore drops the target and renames the source into place;" >&2
  echo "        if you want to just rename source→target directly, use psql manually)" >&2
  exit 1
fi

if [ "$SOURCE_DB" = "$TARGET_DB" ]; then
  echo "ERROR: source and target are the same database ($SOURCE_DB)" >&2
  exit 1
fi

# Confirmation
if [ "${CONFIRMED:-}" != "yes" ]; then
  {
    echo "About to restore database in env=$ENV:"
    echo "  DROP current '$TARGET_DB' (destroys its contents)"
    echo "  Rename '$SOURCE_DB' → '$TARGET_DB'"
    echo ""
    echo "'$TARGET_DB''s current data will be LOST. Ensure you have a"
    echo "recent backup if you might want it later."
    echo ""
    echo "During the window, ANY app using '$TARGET_DB' will error."
    echo "If this is a live app, put it in maintenance mode FIRST."
  } >&2
  read -r -p "Type 'yes' to continue: " ANS
  if [ "$ANS" != "yes" ]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

echo "=== db-restore: $ENV / $SOURCE_DB → $TARGET_DB ===" >&2

psql-env "$ENV" -d postgres <<SQL >&2
GRANT $APP_USER TO dbadmin;
ALTER DATABASE $TARGET_DB OWNER TO dbadmin;
REVOKE CONNECT ON DATABASE $TARGET_DB FROM PUBLIC, $APP_USER;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname='$TARGET_DB' AND pid<>pg_backend_pid();
DROP DATABASE $TARGET_DB;
ALTER DATABASE $SOURCE_DB RENAME TO $TARGET_DB;
GRANT CONNECT ON DATABASE $TARGET_DB TO $APP_USER;
REVOKE $APP_USER FROM dbadmin;
SQL

echo "" >&2
echo "OK: dropped $TARGET_DB, renamed $SOURCE_DB → $TARGET_DB" >&2
echo "$TARGET_DB is now populated with what was in $SOURCE_DB." >&2
echo "" >&2
echo "Recommend: run 'make clear-drupal-cache ENV=$ENV' to invalidate" >&2
echo "any Valkey/on-disk caches referencing the previous state." >&2
