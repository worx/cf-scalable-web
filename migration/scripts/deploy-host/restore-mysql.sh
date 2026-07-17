#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/restore-mysql.sh
#
# Purpose:  Restore the prod MySQL dump (staged in S3 by the jumpbox
#           side's dump-mysql.sh) into a fresh local MariaDB scratch
#           database on the sandbox deploy-host, ready for pgloader
#           to consume in the next step.
#
# Flow (six phases, each logged separately):
#   1. Preconditions        (root, tools, mariadb up, socket auth)
#   2. Confirmation         (DROP DATABASE is destructive — honors CONFIRMED=yes)
#   3. Fetch dump from S3   (reuses cached local file unless FORCE_DOWNLOAD=yes)
#   4. Sanitize the dump    (sed utf8mb4_0900_ai_ci → utf8mb4_unicode_ci if present)
#   5. Reset local DB+user  (DROP DATABASE, CREATE, worxco@127.0.0.1 with
#                            mysql_native_password for pgloader/qmynd compat)
#   6. Restore              (mysql < dump), then verify table count is sane
#
# Idempotent:
#   - Safe to re-run: DROP + CREATE ensures no leftover state
#   - Existing local dump is reused unless FORCE_DOWNLOAD=yes
#   - Sed step is a no-op if the collation isn't in the file
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   S3 bucket holding the dump    (sandbox-migration-kv-worxco)
#   DUMP_S3_KEY        Object key in that bucket    (dumps/zinew.sql)
#   DUMP_LOCAL_PATH    Local staging path            (/var/www/mysql/zinew.sql)
#   LOCAL_DB_NAME      Target scratch DB name        (zinew)
#   LOCAL_DB_USER      DB user for pgloader          (worxco)
#   LOCAL_DB_PASS      DB password (scratch only)    (localscratchpass)
#   FORCE_DOWNLOAD     yes = re-download from S3 even if local file exists
#   CONFIRMED          yes = skip interactive Y/N confirmation prompt
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  root (via sudo). Needs socket auth for MariaDB root, S3 read
#           via the deploy-host's IAM instance profile, and write access
#           to DUMP_LOCAL_PATH's directory.
# Host:     deploy-host (sandbox VPC)
# Invoked:  Directly (sudo ./restore-mysql.sh) or via a future make target
#
# Logging:  Written to /var/log/worxco-migration/restore-mysql-<UTC>.log
#           and uploaded to s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-10
# ============================================================

set -euo pipefail

# Source the shared helper library (colors, logging, confirm, dry-run, ...)
# _common.sh lives one directory up from this script (migration/scripts/).
source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/zinew.sql}"
DUMP_LOCAL_PATH="${DUMP_LOCAL_PATH:-/var/www/mysql/zinew.sql}"
LOCAL_DB_NAME="${LOCAL_DB_NAME:-zinew}"
LOCAL_DB_USER="${LOCAL_DB_USER:-worxco}"
LOCAL_DB_PASS="${LOCAL_DB_PASS:-localscratchpass}"

# ============================================================
# Set up logging + on-exit S3 upload of the log file
# ============================================================
log_init "restore-mysql"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "restore-mysql — Prod MySQL dump → local MariaDB scratch"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "DUMP_S3_KEY      = $DUMP_S3_KEY"
log_info "DUMP_LOCAL_PATH  = $DUMP_LOCAL_PATH"
log_info "LOCAL_DB_NAME    = $LOCAL_DB_NAME"
log_info "LOCAL_DB_USER    = $LOCAL_DB_USER"
log_info "LOCAL_DB_PASS    = $(mask_secret "$LOCAL_DB_PASS")"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root (use sudo)."
  log_info  "Example: sudo -E ./restore-mysql.sh   (the -E preserves your env vars)"
  exit 1
fi

require_env MIGRATION_BUCKET DUMP_S3_KEY DUMP_LOCAL_PATH \
            LOCAL_DB_NAME LOCAL_DB_USER LOCAL_DB_PASS

# Required tools on the PATH
for tool in mysql aws sed grep stat; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    exit 1
  fi
done
log_ok "All required tools available"

# MariaDB must be running (systemd). Bootstrap.sh installs but disables
# the unit to save idle RAM; auto-start it here on first use of this script.
if ! systemctl is-active --quiet mariadb 2>/dev/null; then
  log_info "MariaDB service not active — attempting to start..."
  if systemctl start mariadb 2>/dev/null && systemctl is-active --quiet mariadb; then
    log_ok "MariaDB service started"
  else
    log_error "Failed to start MariaDB service."
    log_info  "Check: sudo systemctl status mariadb"
    log_info  "Or install (if missing): sudo apt install -y mariadb-server mariadb-client"
    exit 1
  fi
else
  log_ok "MariaDB service is active"
fi

# MariaDB root access via socket auth (default when run as root)
if ! mysql -e "SELECT VERSION();" >/dev/null 2>&1; then
  log_error "Cannot connect to local MariaDB as root via socket."
  log_info  "Try:  sudo mysql -e 'SELECT VERSION();'"
  log_info  "If that fails, root's auth plugin may have drifted from auth_socket."
  exit 1
fi
MARIADB_VERSION=$(mysql -N -e "SELECT VERSION();")
log_ok "MariaDB socket auth working (version: $MARIADB_VERSION)"

# ============================================================
# Phase 2 of 6: Confirmation
# ============================================================
log_step "Phase 2/6: Confirmation"

confirm_or_exit "About to DROP DATABASE \`$LOCAL_DB_NAME\` on local MariaDB and restore from S3.
    Source: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Target: local MariaDB, database '$LOCAL_DB_NAME'
    User:   $LOCAL_DB_USER@127.0.0.1 (recreated with mysql_native_password)
    All existing data in $LOCAL_DB_NAME will be lost."

# ============================================================
# Phase 3 of 6: Fetch dump from S3 (or reuse cached local file)
# ============================================================
log_step "Phase 3/6: Fetch dump from S3"

DUMP_DIR="$(dirname "$DUMP_LOCAL_PATH")"
if [ ! -d "$DUMP_DIR" ]; then
  log_info "Creating dump staging dir: $DUMP_DIR"
  run_or_echo mkdir -p "$DUMP_DIR"
fi

# Reuse an existing local dump unless FORCE_DOWNLOAD=yes.
if [ -f "$DUMP_LOCAL_PATH" ] && [ "${FORCE_DOWNLOAD:-}" != "yes" ]; then
  SIZE_BYTES=$(stat -c %s "$DUMP_LOCAL_PATH" 2>/dev/null || echo 0)
  SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
  log_info "Reusing cached local dump: $DUMP_LOCAL_PATH (${SIZE_MB} MB)"
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
    SIZE_BYTES=$(stat -c %s "$DUMP_LOCAL_PATH")
    SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
    log_ok "Downloaded ${SIZE_MB} MB in ${time_elapsed}s"
  fi
fi

# Sanity check on the file
if ! is_dry_run; then
  if [ ! -s "$DUMP_LOCAL_PATH" ]; then
    log_error "Dump file is empty or missing: $DUMP_LOCAL_PATH"
    exit 1
  fi
  # A valid mysqldump starts with either -- comments or SET statements
  FIRST_LINE=$(head -1 "$DUMP_LOCAL_PATH")
  if ! echo "$FIRST_LINE" | grep -qE '^(--|SET |/\*)'; then
    log_warn "First line of dump doesn't look like mysqldump output:"
    log_warn "  '$FIRST_LINE'"
    log_warn "(Proceeding anyway, but restore may fail.)"
  fi
fi

# ============================================================
# Phase 4 of 6: Sanitize dump (MySQL 8 → MariaDB collation fix)
# ============================================================
log_step "Phase 4/6: Sanitize dump for MariaDB compatibility"

# Aurora MySQL 8's default collation `utf8mb4_0900_ai_ci` doesn't exist
# in MariaDB. Substitute with `utf8mb4_unicode_ci` which is well-supported
# by both MariaDB and qmynd (pgloader's MySQL driver). The grep-first
# pattern makes this a no-op when the dump is already sanitized (safe
# to re-run after DUMP_LOCAL_PATH was already processed).
if is_dry_run; then
  log_info "[DRY_RUN] would grep for utf8mb4_0900_ai_ci and sed if present"
elif grep -q 'utf8mb4_0900_ai_ci' "$DUMP_LOCAL_PATH"; then
  MATCHES=$(grep -c 'utf8mb4_0900_ai_ci' "$DUMP_LOCAL_PATH")
  log_info "Found $MATCHES occurrence(s) of utf8mb4_0900_ai_ci — sed replacing..."
  time_start=$SECONDS
  sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' "$DUMP_LOCAL_PATH"
  time_elapsed=$(( SECONDS - time_start ))
  # Verify the substitution took
  if grep -q 'utf8mb4_0900_ai_ci' "$DUMP_LOCAL_PATH"; then
    log_error "sed did not fully replace utf8mb4_0900_ai_ci — aborting"
    exit 1
  fi
  log_ok "Collation sanitized (${time_elapsed}s)"
else
  log_info "No utf8mb4_0900_ai_ci found — dump is already MariaDB-compatible"
fi

# ============================================================
# Phase 5 of 6: Reset local database and user
# ============================================================
log_step "Phase 5/6: Reset local database and user"

# The 5-statement block below is the entire local-DB provisioning:
#   1. DROP: clean slate
#   2. CREATE: fresh DB with sensible charset defaults
#   3. CREATE USER IF NOT EXISTS: idempotent user creation
#   4. ALTER USER: (re)set password AND force mysql_native_password plugin
#      — qmynd (pgloader's Common Lisp MySQL driver) can't handle
#      caching_sha2_password. MariaDB defaults to native, but ALTER
#      makes it explicit and survives re-runs.
#   5. GRANT + FLUSH: privileges
if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  log_info "  DROP DATABASE IF EXISTS \`$LOCAL_DB_NAME\`;"
  log_info "  CREATE DATABASE \`$LOCAL_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  log_info "  CREATE USER IF NOT EXISTS '$LOCAL_DB_USER'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD(...);"
  log_info "  ALTER USER '$LOCAL_DB_USER'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD(...);"
  log_info "  GRANT ALL PRIVILEGES ON \`$LOCAL_DB_NAME\`.* TO '$LOCAL_DB_USER'@'127.0.0.1'; FLUSH PRIVILEGES;"
else
  mysql <<SQL
DROP DATABASE IF EXISTS \`$LOCAL_DB_NAME\`;
CREATE DATABASE \`$LOCAL_DB_NAME\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$LOCAL_DB_USER'@'127.0.0.1'
  IDENTIFIED VIA mysql_native_password
  USING PASSWORD('$LOCAL_DB_PASS');
ALTER USER '$LOCAL_DB_USER'@'127.0.0.1'
  IDENTIFIED VIA mysql_native_password
  USING PASSWORD('$LOCAL_DB_PASS');
GRANT ALL PRIVILEGES ON \`$LOCAL_DB_NAME\`.* TO '$LOCAL_DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  # Verify the user record
  USER_PLUGIN=$(mysql -N -e "SELECT plugin FROM mysql.user WHERE user='$LOCAL_DB_USER' AND host='127.0.0.1';")
  if [ "$USER_PLUGIN" != "mysql_native_password" ]; then
    log_error "$LOCAL_DB_USER@127.0.0.1 has wrong plugin: '$USER_PLUGIN' (expected mysql_native_password)"
    exit 1
  fi
  log_ok "Database $LOCAL_DB_NAME ready; $LOCAL_DB_USER@127.0.0.1 configured with mysql_native_password"
fi

# ============================================================
# Phase 6 of 6: Restore + verify
# ============================================================
log_step "Phase 6/6: Restore dump into $LOCAL_DB_NAME"

if is_dry_run; then
  log_info "[DRY_RUN] would run: mysql -h 127.0.0.1 -u $LOCAL_DB_USER -p*** $LOCAL_DB_NAME < $DUMP_LOCAL_PATH"
else
  SIZE_BYTES=$(stat -c %s "$DUMP_LOCAL_PATH")
  SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
  log_info "Restoring ${SIZE_MB} MB via mysql client (this can take several minutes)..."
  time_start=$SECONDS

  # Password is passed on the command line here — for a scratch DB
  # inside a sandbox VPC this is acceptable. If ever adapted for a
  # non-scratch environment, switch to --defaults-extra-file with a
  # mode-600 temp file so the password doesn't appear in ps output.
  mysql -h 127.0.0.1 -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASS" "$LOCAL_DB_NAME" < "$DUMP_LOCAL_PATH"

  time_elapsed=$(( SECONDS - time_start ))
  log_ok "Restore complete in ${time_elapsed}s ($(( SIZE_MB * 60 / (time_elapsed + 1) )) MB/min)"

  # ---- Verification ----
  TABLE_COUNT=$(mysql -N -e "
    SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='$LOCAL_DB_NAME' AND table_type='BASE TABLE';")

  if [ "$TABLE_COUNT" -eq 0 ]; then
    log_error "Restore completed but zero tables were created — something is wrong."
    log_error "Check the dump file's contents and the MariaDB error log."
    exit 1
  fi
  log_ok "Table count in $LOCAL_DB_NAME: $TABLE_COUNT"

  # Show the top 5 largest tables so the operator can eyeball vs prod
  log_info "Top 5 tables by row count (MySQL's estimate):"
  mysql -N -e "
    SELECT table_name, COALESCE(table_rows,0) AS approx_rows
      FROM information_schema.tables
     WHERE table_schema='$LOCAL_DB_NAME' AND table_type='BASE TABLE'
     ORDER BY table_rows DESC LIMIT 5;" \
  | while IFS=$'\t' read -r name rows; do
      printf '    %-40s  %s rows\n' "$name" "$rows"
    done
fi

# ============================================================
# Done
# ============================================================
log_step "restore-mysql complete"
log_ok "Local scratch database '$LOCAL_DB_NAME' is ready for pgloader"
log_info "Next step: run pgloader to convert MariaDB → PostgreSQL"
log_info "  (upcoming target: run-pgloader.sh or 'make db-pgloader' from migration/)"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
