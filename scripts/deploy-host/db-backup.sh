#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/db-backup.sh
#
# Purpose:  Snapshot a live PostgreSQL database via the surgical
#           logical-DB rename pattern (see
#           docs/memory/db-rollback-pattern.md):
#             1. Rename current <db_name> → <db_name>_backup_<UTC>
#             2. Create fresh empty <db_name> owned by the app user
#           Metadata-only, sub-second, application-transparent once
#           repopulated. Rollback via db-restore.sh (or manual
#           ALTER DATABASE ... RENAME).
#
# Usage:    sudo scripts/deploy-host/db-backup.sh <env> [db_name]
# Example:  sudo scripts/deploy-host/db-backup.sh sandbox drupal
#           sudo scripts/deploy-host/db-backup.sh sandbox         # DB defaults to drupal
#
# Preconditions:
#   - /etc/worxco/envs/<env> readable (sets DRUPAL_DB_USER etc.)
#   - psql-env <env> works (RDS reachable, dbadmin creds valid)
#   - CONFIRMED=yes in env, or interactive TTY for prompt
#
# Post-run state:
#   - <db_name> = fresh empty, owned by DRUPAL_DB_USER
#   - <db_name>_backup_<UTC> = full copy of pre-run state, owned by
#     DRUPAL_DB_USER
#   - Role graph unchanged (transient GRANT/REVOKE of app-user
#     membership on dbadmin — undone within the same session)
#
# Output:
#   - Status/progress to stderr
#   - New backup DB name to stdout (one line, machine-parseable)
#
# Application impact:
#   - App using <db_name> will error until <db_name> is repopulated.
#     For a live app, put it in maintenance mode BEFORE running this.
#     For a scratch/empty DB, just run.

set -euo pipefail

ENV="${1:-}"
DB_NAME="${2:-drupal}"

if [ -z "$ENV" ]; then
  echo "Usage: $0 <env> [db_name]" >&2
  echo "Example: $0 sandbox drupal" >&2
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

# Verify the target DB exists
if ! psql-env "$ENV" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q '^1$'; then
  echo "ERROR: database '$DB_NAME' does not exist in env=$ENV" >&2
  echo "       Use 'psql-env $ENV -d postgres -c \\\\l' to list databases" >&2
  exit 1
fi

STAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_DB="${DB_NAME}_backup_$STAMP"

# Confirmation
if [ "${CONFIRMED:-}" != "yes" ]; then
  {
    echo "About to snapshot database '$DB_NAME' in env=$ENV:"
    echo "  Rename current $DB_NAME → $BACKUP_DB (preserved as backup)"
    echo "  Create fresh empty $DB_NAME (owned by $APP_USER)"
    echo ""
    echo "During the window between rename and repopulation, ANY app using"
    echo "$DB_NAME will error. If this is a live app, put it in maintenance"
    echo "mode FIRST."
  } >&2
  read -r -p "Type 'yes' to continue: " ANS
  if [ "$ANS" != "yes" ]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

echo "=== db-backup: $ENV / $DB_NAME → $BACKUP_DB ===" >&2

psql-env "$ENV" -d postgres <<SQL >&2
GRANT $APP_USER TO dbadmin;
ALTER DATABASE $DB_NAME OWNER TO dbadmin;
REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC, $APP_USER;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname='$DB_NAME' AND pid<>pg_backend_pid();
ALTER DATABASE $DB_NAME RENAME TO $BACKUP_DB;
CREATE DATABASE $DB_NAME OWNER $APP_USER;
ALTER DATABASE $BACKUP_DB OWNER TO $APP_USER;
GRANT CONNECT ON DATABASE $DB_NAME TO $APP_USER;
GRANT CONNECT ON DATABASE $BACKUP_DB TO $APP_USER;
REVOKE $APP_USER FROM dbadmin;
SQL

echo "" >&2
echo "OK: renamed $DB_NAME → $BACKUP_DB, created fresh empty $DB_NAME" >&2

# Machine-parseable output on stdout
echo "$BACKUP_DB"
