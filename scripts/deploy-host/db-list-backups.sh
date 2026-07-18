#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/db-list-backups.sh
#
# Purpose:  List logical-DB backups (databases whose name matches
#           `<prefix>_backup_%`), sorted newest-first, with size and
#           owner info.
#
# Usage:    scripts/deploy-host/db-list-backups.sh <env> [db_prefix]
# Example:  scripts/deploy-host/db-list-backups.sh sandbox
#           scripts/deploy-host/db-list-backups.sh sandbox drupal
#
# Read-only. No sudo required (psql-env handles master creds).

set -euo pipefail

ENV="${1:-}"
DB_PREFIX="${2:-drupal}"

if [ -z "$ENV" ]; then
  echo "Usage: $0 <env> [db_prefix]" >&2
  echo "Example: $0 sandbox drupal" >&2
  exit 1
fi

psql-env "$ENV" -d postgres <<SQL
SELECT datname                                    AS backup_name,
       pg_get_userbyid(datdba)                    AS owner,
       pg_size_pretty(pg_database_size(datname))  AS size
FROM pg_database
WHERE datname LIKE '${DB_PREFIX}_backup_%'
ORDER BY datname DESC;
SQL
