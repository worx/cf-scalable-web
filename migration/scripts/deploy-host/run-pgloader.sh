#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/deploy-host/run-pgloader.sh
#
# Purpose:  Run pgloader against the local MariaDB scratch DB
#           (populated by restore-mysql.sh) and load the data into
#           the sandbox RDS PostgreSQL target, applying the tuned
#           WITH/CAST clauses baked into
#           migration/pgloader/zinew.load.tmpl.
#
# Flow (six phases, each logged separately):
#   1. Preconditions    (root, tools, mariadb running, template exists,
#                        RDS reachable via 5432)
#   2. Env sourcing     (source /etc/worxco/envs/sandbox → DRUPAL_DB_*)
#                        + password URL-encoding (SANDBOX_PW_ENC) if
#                        the env only has the raw password.
#   3. Confirmation     (`include drop` in the load file wipes the
#                        target DB — honors CONFIRMED=yes)
#   4. Render template  (envsubst zinew.load.tmpl → /tmp/zinew.load,
#                        chmod 600; contains the URL-encoded RDS
#                        master password)
#   5. Run pgloader     (--dynamic-space-size 4096
#                        --no-ssl-cert-verification zinew.load)
#   6. Cleanup + verify (shred rendered file; query target for
#                        table count)
#
# Idempotent:
#   - Safe to re-run: the load file itself uses `include drop` so
#     each run rebuilds the target schema from scratch
#   - Rendered /tmp/zinew.load is shredded after every run so a
#     failed/killed run can't leak the RDS password
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   S3 bucket holding logs   (sandbox-migration-kv-worxco)
#   ENV_FILE           Path to sandbox env file (/etc/worxco/envs/sandbox)
#   TEMPLATE_PATH      pgloader .load template  (<repo>/migration/pgloader/zinew.load.tmpl)
#   RENDERED_PATH      Rendered .load path      (/tmp/zinew.load)
#   PGLOADER_HEAP_MB   SBCL dynamic-space-size  (4096 — 4 GB)
#   CONFIRMED          yes = skip interactive Y/N confirmation prompt
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  root (via sudo). Needs local MariaDB access, network access
#           to sandbox RDS, S3 write for the log upload (via the
#           deploy-host's IAM instance profile).
# Host:     deploy-host (sandbox VPC)
# Invoked:  Directly (sudo ./run-pgloader.sh) or via `make run-pgloader`
#           from the migration/ Makefile.
#
# Logging:  Written to /var/log/worxco-migration/run-pgloader-<UTC>.log
#           and uploaded to s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-15
# ============================================================

set -euo pipefail

# Source the shared helper library (colors, logging, confirm, dry-run, ...)
# _common.sh lives one directory up from this script (migration/scripts/).
source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_MIGRATION_DIR="$(readlink -f "$SCRIPT_DIR/../..")"

MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
ENV_FILE="${ENV_FILE:-/etc/worxco/envs/sandbox}"
TEMPLATE_PATH="${TEMPLATE_PATH:-$REPO_MIGRATION_DIR/pgloader/zinew.load.tmpl}"
RENDERED_PATH="${RENDERED_PATH:-/tmp/zinew.load}"
PGLOADER_HEAP_MB="${PGLOADER_HEAP_MB:-4096}"

# ============================================================
# Set up logging + on-exit S3 upload of the log file
# ============================================================
log_init "run-pgloader"
trap 'log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

# Also shred the rendered .load file on any exit path — it contains
# the URL-encoded RDS master password. Bash keeps only ONE handler
# per signal, so combine shred + log upload into a single trap.
#
# log_upload_and_exit captures $? on its first line, so we `(exit $rc)`
# right before calling it to restore the outgoing exit code that the
# shred/rm chain would otherwise have clobbered.
_cleanup() {
  local rc=$?
  if [ -f "$RENDERED_PATH" ]; then
    shred -u "$RENDERED_PATH" 2>/dev/null \
      || rm -f "$RENDERED_PATH" 2>/dev/null || true
  fi
  (exit "$rc")
  log_upload_and_exit "$MIGRATION_BUCKET"
}
trap _cleanup EXIT

log_step "run-pgloader — local MariaDB scratch → sandbox RDS PostgreSQL"
log_info "MIGRATION_BUCKET  = $MIGRATION_BUCKET"
log_info "ENV_FILE          = $ENV_FILE"
log_info "TEMPLATE_PATH     = $TEMPLATE_PATH"
log_info "RENDERED_PATH     = $RENDERED_PATH"
log_info "PGLOADER_HEAP_MB  = $PGLOADER_HEAP_MB"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root (use sudo)."
  log_info  "Example: sudo -E ./run-pgloader.sh   (the -E preserves your env vars)"
  exit 1
fi

# Required tools on the PATH.
# envsubst comes from gettext-base — usually preinstalled on Ubuntu Server
# but explicitly checked here in case a slimmer image is ever used.
for tool in pgloader mysql psql jq envsubst shred aws; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    case "$tool" in
      envsubst) log_info "Install: sudo apt install -y gettext-base" ;;
      pgloader) log_info "Install: sudo apt install -y pgloader" ;;
      *) : ;;
    esac
    exit 1
  fi
done
log_ok "All required tools available"

# Template must exist
if [ ! -f "$TEMPLATE_PATH" ]; then
  log_error "pgloader template not found: $TEMPLATE_PATH"
  log_info  "Expected: <repo>/migration/pgloader/zinew.load.tmpl"
  exit 1
fi
log_ok "Template file present: $TEMPLATE_PATH"

# MariaDB must be running (auto-start if disabled — same policy as restore-mysql.sh).
if ! systemctl is-active --quiet mariadb 2>/dev/null; then
  log_info "MariaDB service not active — attempting to start..."
  if systemctl start mariadb 2>/dev/null && systemctl is-active --quiet mariadb; then
    log_ok "MariaDB service started"
  else
    log_error "Failed to start MariaDB service."
    log_info  "Check: sudo systemctl status mariadb"
    exit 1
  fi
else
  log_ok "MariaDB service is active"
fi

# Verify the scratch DB is populated (fail fast if restore-mysql.sh
# hasn't been run yet — running pgloader against an empty source
# would happily rebuild the target with zero tables).
SOURCE_TABLE_COUNT=$(mysql -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zinew';" \
  2>/dev/null || echo 0)
if [ "$SOURCE_TABLE_COUNT" -lt 1 ]; then
  log_error "Source scratch DB 'zinew' has 0 tables — nothing to migrate."
  log_info  "Populate first: make restore-mysql"
  exit 1
fi
log_ok "Source 'zinew' DB has $SOURCE_TABLE_COUNT tables"

# ============================================================
# Phase 2 of 6: Env sourcing + password encoding
# ============================================================
log_step "Phase 2/6: Source env file + prep RDS connection vars"

if [ ! -r "$ENV_FILE" ]; then
  log_error "Env file not readable: $ENV_FILE"
  log_info  "Refresh cache: sudo refresh-env-config sandbox"
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Required RDS vars (env file must provide these).
for var in DRUPAL_DB_USER DRUPAL_DB_HOST DRUPAL_DB_PORT DRUPAL_DB_NAME; do
  if [ -z "${!var:-}" ]; then
    log_error "Env var '$var' not set after sourcing $ENV_FILE."
    log_info  "Rebuild env file: sudo refresh-env-config sandbox"
    exit 1
  fi
done

# Password: env may provide SANDBOX_PW_ENC (URL-encoded, preferred) or
# SANDBOX_PW (raw). We URL-encode via jq if only the raw form is set.
if [ -z "${SANDBOX_PW_ENC:-}" ]; then
  if [ -n "${SANDBOX_PW:-}" ]; then
    SANDBOX_PW_ENC=$(jq -rn --arg s "$SANDBOX_PW" '$s|@uri')
    log_info "SANDBOX_PW_ENC computed from SANDBOX_PW (URL-encoded via jq)"
  else
    log_error "Neither SANDBOX_PW_ENC nor SANDBOX_PW is set."
    log_info  "Rebuild env file: sudo refresh-env-config sandbox"
    exit 1
  fi
fi
export DRUPAL_DB_USER DRUPAL_DB_HOST DRUPAL_DB_PORT DRUPAL_DB_NAME SANDBOX_PW_ENC

log_info "DRUPAL_DB_USER    = $DRUPAL_DB_USER"
log_info "DRUPAL_DB_HOST    = $DRUPAL_DB_HOST"
log_info "DRUPAL_DB_PORT    = $DRUPAL_DB_PORT"
log_info "DRUPAL_DB_NAME    = $DRUPAL_DB_NAME"
log_info "SANDBOX_PW_ENC    = $(mask_secret "$SANDBOX_PW_ENC")"

# RDS reachability sanity check (TCP connect only — psql auth
# might fail for other reasons, we don't want to confuse errors).
if ! timeout 5 bash -c "</dev/tcp/$DRUPAL_DB_HOST/$DRUPAL_DB_PORT" 2>/dev/null; then
  log_error "Cannot reach RDS at $DRUPAL_DB_HOST:$DRUPAL_DB_PORT (5s TCP timeout)."
  log_info  "Check RDS security group + deploy-host VPC routing."
  exit 1
fi
log_ok "RDS reachable at $DRUPAL_DB_HOST:$DRUPAL_DB_PORT"

# ============================================================
# Phase 3 of 6: Confirmation
# ============================================================
log_step "Phase 3/6: Confirmation"

confirm_or_exit "About to REBUILD the sandbox RDS PostgreSQL target from local MariaDB.
    Source: mysql://worxco@127.0.0.1:3306/zinew ($SOURCE_TABLE_COUNT tables)
    Target: postgresql://$DRUPAL_DB_USER@$DRUPAL_DB_HOST:$DRUPAL_DB_PORT/$DRUPAL_DB_NAME
    The load file has 'include drop' — every table in the target
    schema will be dropped and recreated. Any manual PostgreSQL
    state (custom indexes, permissions, etc.) will be lost."

# ============================================================
# Phase 4 of 6: Render template → /tmp/zinew.load (chmod 600)
# ============================================================
log_step "Phase 4/6: Render pgloader load file"

if [ "${DRY_RUN:-}" = "yes" ]; then
  log_info "DRY_RUN: would render $TEMPLATE_PATH → $RENDERED_PATH"
else
  # envsubst only replaces the vars we explicitly enumerate, so a
  # literal ${...} that isn't in our whitelist survives untouched.
  # (Belt-and-suspenders — the template doesn't have any other
  # ${...} references today, but this guards a future edit.)
  envsubst '${DRUPAL_DB_USER} ${SANDBOX_PW_ENC} ${DRUPAL_DB_HOST} ${DRUPAL_DB_PORT} ${DRUPAL_DB_NAME}' \
    < "$TEMPLATE_PATH" > "$RENDERED_PATH"
  chmod 600 "$RENDERED_PATH"
  log_ok "Rendered to $RENDERED_PATH (chmod 600)"
fi

# ============================================================
# Phase 5 of 6: Run pgloader
# ============================================================
log_step "Phase 5/6: Run pgloader"

if [ "${DRY_RUN:-}" = "yes" ]; then
  log_info "DRY_RUN: would run pgloader --dynamic-space-size $PGLOADER_HEAP_MB --no-ssl-cert-verification $RENDERED_PATH"
else
  # pgloader logs both stdout + stderr; both get tee'd into our
  # log file by log_init's exec redirection.
  # NOTE: --no-ssl-cert-verification is required because pgloader's
  # PostgreSQL driver can't validate the RDS CA chain out of the
  # box; the TCP connection itself is still TLS-encrypted (sslmode=require
  # in the load file).
  pgloader --dynamic-space-size "$PGLOADER_HEAP_MB" \
           --no-ssl-cert-verification \
           "$RENDERED_PATH"
fi
log_ok "pgloader completed"

# ============================================================
# Phase 6 of 6: Cleanup + verify
# ============================================================
log_step "Phase 6/6: Cleanup + verify"

# The EXIT trap will shred RENDERED_PATH, but do it eagerly here
# too so the "verify" step below doesn't see the sensitive file
# hanging around.
if [ -f "$RENDERED_PATH" ]; then
  shred -u "$RENDERED_PATH" 2>/dev/null || rm -f "$RENDERED_PATH" || true
  log_ok "Rendered load file shredded"
fi

# Verify target has tables. Use PGPASSWORD instead of putting the
# password in the psql URL to keep it out of process listings.
if [ "${DRY_RUN:-}" != "yes" ]; then
  TARGET_TABLE_COUNT=$(
    PGPASSWORD="$SANDBOX_PW_ENC" psql \
      -h "$DRUPAL_DB_HOST" -p "$DRUPAL_DB_PORT" \
      -U "$DRUPAL_DB_USER" -d "$DRUPAL_DB_NAME" \
      -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" \
      2>/dev/null || echo 0
  )
  log_info "Target PostgreSQL 'public' schema now has $TARGET_TABLE_COUNT tables"
  if [ "$TARGET_TABLE_COUNT" -lt "$((SOURCE_TABLE_COUNT / 2))" ]; then
    log_warn "Target table count ($TARGET_TABLE_COUNT) is well below source ($SOURCE_TABLE_COUNT)."
    log_warn "pgloader may have skipped tables — review the log above."
  fi
fi

log_ok "run-pgloader complete"
