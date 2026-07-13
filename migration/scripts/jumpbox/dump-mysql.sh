#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/dump-mysql.sh
#
# Purpose:  Dump the prod MySQL zinew database via mysqldump and stream
#           it directly to the sandbox S3 migration bucket — no local
#           staging on the jumpbox (an 8 GB root volume can't safely
#           hold multi-GB dumps).
#
# Flow (six phases, each logged separately):
#   1. Preconditions       (tools, env vars)
#   2. Fetch credentials   (Secrets Manager → mysql defaults-file)
#   3. Test connection     (mysql SELECT VERSION + table count + size)
#   4. Confirmation        (mysqldump adds prod read load — honors CONFIRMED=yes)
#   5. Stream dump → S3    (single pipeline, pipefail on)
#   6. Verify S3 upload    (head-object; fail if suspiciously small)
#
# Idempotent: yes — S3 PUT is atomic, so re-runs overwrite the previous
#   dump cleanly. There's no local intermediate to clean up between runs.
#
# Environment variables (all optional, listed with defaults):
#   MIGRATION_BUCKET   Sandbox S3 bucket        (sandbox-migration-kv-worxco)
#   SECRET_NAME        Prod Secrets Manager id  (cf-migration/prod-mysql-zinew)
#   DUMP_S3_KEY        Target object key         (dumps/zinew.sql)
#   CONFIRMED          yes = skip interactive Y/N confirmation
#   DRY_RUN            yes = preview commands without executing
#
# Runs as:  ubuntu on the jumpbox (or root via SSM send-command). The
#           jumpbox's instance role provides cross-account S3 write to
#           MIGRATION_BUCKET and secretsmanager:GetSecretValue on the
#           specific secret's ARN.
# Host:     Prod jumpbox (EC2 in vpc-7fbd291a, prod account 978068244875)
# Called by:
#   - Directly (in an SSM interactive session)
#   - By a future Makefile target that pushes this script to the jumpbox
#     via S3 and executes it via `aws ssm send-command`
#
# Logging:  Written to /var/log/worxco-migration/dump-mysql-<UTC>.log
#           and uploaded to s3://$MIGRATION_BUCKET/logs/YYYY-MM-DD/ on exit.
#
# Created:  2026-07-10
# ============================================================

set -euo pipefail

# Source shared helpers (colors, log_init, confirm_or_exit, ...)
# _common.sh lives one directory up (migration/scripts/).
source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults (all overridable by environment)
# ============================================================
MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
SECRET_NAME="${SECRET_NAME:-cf-migration/prod-mysql-zinew}"
DUMP_S3_KEY="${DUMP_S3_KEY:-dumps/zinew.sql}"

# Filled in during Phase 2 — declared here so the cleanup trap can see them
CREDFILE=""
PROD_HOST=""
PROD_PORT=""
PROD_DB=""
PROD_USER=""
PROD_PASS=""

# ============================================================
# Cleanup + log upload — runs on any exit, clean or errored
# ============================================================
# Chain two on-exit actions: shred the credentials file first (so if
# something's watching the process table it doesn't linger a moment
# longer than necessary), then upload the log to S3.
_dump_mysql_cleanup() {
  if [ -n "$CREDFILE" ] && [ -f "$CREDFILE" ]; then
    # `shred` isn't guaranteed on all images; fall back to rm+overwrite
    if command -v shred >/dev/null 2>&1; then
      shred -u "$CREDFILE" 2>/dev/null || rm -f "$CREDFILE"
    else
      rm -f "$CREDFILE"
    fi
  fi
  unset PROD_PASS  # in case anything's read the env in this shell
}

log_init "dump-mysql"
trap '_dump_mysql_cleanup; log_upload_and_exit "$MIGRATION_BUCKET"' EXIT

log_step "dump-mysql — Prod MySQL → sandbox S3 (streamed)"
log_info "MIGRATION_BUCKET = $MIGRATION_BUCKET"
log_info "SECRET_NAME      = $SECRET_NAME"
log_info "DUMP_S3_KEY      = $DUMP_S3_KEY"
if [ "${DRY_RUN:-}" = "yes" ]; then
  log_warn "DRY_RUN=yes — commands will be previewed, not executed"
fi

# ============================================================
# Phase 1 of 6: Preconditions
# ============================================================
log_step "Phase 1/6: Preconditions"

require_env MIGRATION_BUCKET SECRET_NAME DUMP_S3_KEY

# Tools on PATH. On the jumpbox these come from the UserData bootstrap.
for tool in mysqldump mysql aws jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool '$tool' not found on PATH."
    log_error "The jumpbox UserData installs these; check the instance."
    exit 1
  fi
done
log_ok "All required tools available"

# Confirm we have working AWS credentials (instance role or profile)
if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  log_error "AWS credentials are not working. Check instance role attachment or profile config."
  exit 1
fi
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
log_ok "AWS credentials working — running in account $CURRENT_ACCOUNT"

# ============================================================
# Phase 2 of 6: Fetch credentials from Secrets Manager
# ============================================================
log_step "Phase 2/6: Fetch credentials from Secrets Manager"

log_info "Retrieving secret: $SECRET_NAME"
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --query SecretString \
    --output text 2>&1) || {
  log_error "Failed to get secret '$SECRET_NAME'"
  log_error "  Detail: $SECRET_JSON"
  log_error "  Check the instance role has secretsmanager:GetSecretValue"
  log_error "  scoped to this secret's ARN."
  exit 1
}

# Parse the JSON secret
PROD_HOST=$(printf '%s' "$SECRET_JSON" | jq -r '.host // empty')
PROD_PORT=$(printf '%s' "$SECRET_JSON" | jq -r '.port // empty')
PROD_DB=$(printf   '%s' "$SECRET_JSON" | jq -r '.database // empty')
PROD_USER=$(printf '%s' "$SECRET_JSON" | jq -r '.username // empty')
PROD_PASS=$(printf '%s' "$SECRET_JSON" | jq -r '.password // empty')

# Validate every field is populated (empty means the secret is malformed)
for field in PROD_HOST PROD_PORT PROD_DB PROD_USER PROD_PASS; do
  if [ -z "${!field}" ]; then
    log_error "Secret is missing field: ${field#PROD_}"
    log_error "The secret's SecretString should contain host, port, database, username, password"
    exit 1
  fi
done

# Guard against the placeholder — set-secret-password must have been run
case "$PROD_PASS" in
  PLACEHOLDER-*|placeholder-*)
    log_error "The secret's password is still the placeholder value."
    log_error "From your Mac or deploy-host (with ZoningInfoAdmin profile):"
    log_error "  cd migration && make set-secret-password"
    exit 1
    ;;
esac

log_ok "Fetched credentials: $PROD_USER@$PROD_HOST:$PROD_PORT/$PROD_DB  (pw=$(mask_secret "$PROD_PASS"))"

# Build a mode-600 defaults-file for mysql/mysqldump so the password
# doesn't appear in `ps` output. The cleanup trap shreds it on exit.
CREDFILE=$(mktemp)
chmod 600 "$CREDFILE"
cat > "$CREDFILE" <<EOF
[client]
host=$PROD_HOST
port=$PROD_PORT
user=$PROD_USER
password=$PROD_PASS
EOF
log_ok "Wrote mysql defaults-file: $CREDFILE (mode 600, shredded on exit)"

# ============================================================
# Phase 3 of 6: Test connection + fetch source metadata
# ============================================================
log_step "Phase 3/6: Test connection + fetch source metadata"

if ! mysql --defaults-extra-file="$CREDFILE" -e "SELECT VERSION();" >/dev/null 2>&1; then
  log_error "Cannot connect to prod MySQL at $PROD_HOST:$PROD_PORT"
  log_error "Check network path (jumpbox in same VPC as cluster) and credentials."
  exit 1
fi
MYSQL_VERSION=$(mysql --defaults-extra-file="$CREDFILE" -N -e "SELECT VERSION();")
log_ok "Connected to prod MySQL (server version: $MYSQL_VERSION)"

# Gather source stats — printed for eyeball; passed as expected-count
# to restore-mysql so it can compare after import
TABLE_COUNT=$(mysql --defaults-extra-file="$CREDFILE" -N -e "
  SELECT COUNT(*) FROM information_schema.tables
   WHERE table_schema='$PROD_DB' AND table_type='BASE TABLE';")

DB_SIZE_MB=$(mysql --defaults-extra-file="$CREDFILE" -N -e "
  SELECT COALESCE(ROUND(SUM(data_length + index_length)/1024/1024, 1), 0)
    FROM information_schema.tables
   WHERE table_schema='$PROD_DB';")

if [ "$TABLE_COUNT" -eq 0 ]; then
  log_error "Source database '$PROD_DB' has 0 tables — wrong DB name?"
  exit 1
fi
log_info "Source '$PROD_DB': $TABLE_COUNT tables, ~${DB_SIZE_MB} MB (data + indexes)"

# ============================================================
# Phase 4 of 6: Confirmation
# ============================================================
log_step "Phase 4/6: Confirmation"

confirm_or_exit "About to mysqldump prod MySQL and stream to sandbox S3.
    Source: $PROD_HOST:$PROD_PORT/$PROD_DB (~${DB_SIZE_MB} MB, $TABLE_COUNT tables)
    Target: s3://$MIGRATION_BUCKET/$DUMP_S3_KEY
    Flags:  --single-transaction (no table locks)
            --set-gtid-purged=OFF --column-statistics=0
            --routines --triggers --events
    Warning: this WILL add read load on prod for the dump duration.
    Recommend running off-hours (Kurt's convention: after 5pm)."

# ============================================================
# Phase 5 of 6: Stream dump to S3
# ============================================================
log_step "Phase 5/6: mysqldump → S3 stream"

log_info "Starting mysqldump stream to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
log_info "(may take several minutes for a multi-GB database)"

if is_dry_run; then
  log_info "[DRY_RUN] would run:"
  log_info "  mysqldump --defaults-extra-file=... --single-transaction \\"
  log_info "            --set-gtid-purged=OFF --column-statistics=0 \\"
  log_info "            --routines --triggers --events $PROD_DB \\"
  log_info "    | aws s3 cp - s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
else
  time_start=$SECONDS

  # NOTE on flags:
  #   --single-transaction   REPEATABLE READ snapshot, no InnoDB locks
  #   --set-gtid-purged=OFF  Skip GTID SET statements MariaDB doesn't need
  #   --column-statistics=0  MySQL 8 client feature that older servers reject
  #   --routines --triggers --events  Include stored objects (safe if none)
  #
  # NOTE on pipeline: `set -o pipefail` (from `set -euo pipefail`) means the
  # pipeline's exit code is the last non-zero exit code of any component.
  # So if mysqldump errors, the pipeline errors, we detect it via `if !`,
  # and remove the truncated S3 object.
  if ! mysqldump --defaults-extra-file="$CREDFILE" \
        --single-transaction \
        --set-gtid-purged=OFF \
        --column-statistics=0 \
        --routines --triggers --events \
        "$PROD_DB" \
      | aws s3 cp - "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  then
    log_error "Dump pipeline failed. Removing partial S3 object..."
    aws s3 rm "s3://$MIGRATION_BUCKET/$DUMP_S3_KEY" 2>/dev/null || true
    exit 1
  fi

  time_elapsed=$(( SECONDS - time_start ))
  log_ok "mysqldump → S3 stream completed in ${time_elapsed}s"
fi

# ============================================================
# Phase 6 of 6: Verify S3 upload
# ============================================================
log_step "Phase 6/6: Verify S3 upload"

if is_dry_run; then
  log_info "[DRY_RUN] would run: aws s3api head-object --bucket $MIGRATION_BUCKET --key $DUMP_S3_KEY"
else
  S3_SIZE=$(aws s3api head-object \
      --bucket "$MIGRATION_BUCKET" --key "$DUMP_S3_KEY" \
      --query ContentLength --output text 2>/dev/null || echo "0")

  if [ "$S3_SIZE" = "0" ] || [ -z "$S3_SIZE" ]; then
    log_error "S3 object does not exist or head-object failed."
    exit 1
  fi

  # A minimally-valid mysqldump has SET statements even for an empty DB
  # (~few KB). If we see less than 1 MB for a real Drupal DB, something
  # went badly wrong — likely a mid-stream failure that pipefail didn't
  # catch, or a wildly-wrong PROD_DB target.
  if [ "$S3_SIZE" -lt 1048576 ]; then
    log_error "S3 object is only $S3_SIZE bytes — suspiciously small."
    log_error "Investigate before running restore-mysql on the sandbox side."
    exit 1
  fi

  S3_MB=$(( S3_SIZE / 1024 / 1024 ))
  log_ok "S3 object: ${S3_MB} MB at s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Source-vs-uploaded size check: source data ~${DB_SIZE_MB} MB → dump ${S3_MB} MB"
  log_info "(Dumps are typically 40-80% of source data+index size)"
fi

# ============================================================
# Done
# ============================================================
if is_dry_run; then
  log_step "dump-mysql — DRY RUN complete (no upload performed)"
  log_info "Would have uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_info "Source metadata: $TABLE_COUNT tables, ~${DB_SIZE_MB} MB"
  log_info "Re-run without DRY_RUN=yes to perform the actual dump."
else
  log_step "dump-mysql complete"
  log_ok "Dump uploaded to s3://$MIGRATION_BUCKET/$DUMP_S3_KEY"
  log_ok "Source metadata: $TABLE_COUNT tables, ~${DB_SIZE_MB} MB"
  log_info "Next: on deploy-host, run 'cd migration && make restore-mysql'"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
