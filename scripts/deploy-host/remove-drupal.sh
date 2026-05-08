#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/remove-drupal.sh
#
# Tear down a cloud Drupal install for the named environment:
#   - Drop all tables in the Drupal database (sql:drop)
#   - Wipe /var/www/<env>/drupal, /var/www/<env>/drupal-config
#   - Remove install marker
#
# Does NOT delete:
#   - The database itself (cf-database manages its lifecycle)
#   - The drupal_user PostgreSQL role (left in place for next install)
#   - Secrets Manager entries (intentional — preserve passwords across
#     install/remove cycles. cf-app-drupal.yaml will own these later.)
#   - /var/www/<env>/drupal-private (preserves hash_salt across cycles)
#
# Usage: bash scripts/deploy-host/remove-drupal.sh <env>
#        (or: make remove-drupal ENV=<env>)

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: remove-drupal.sh <env>"
  exit 1
fi

INSTALL_DIR="/var/www/$ENV/drupal"
CONFIG_DIR="/var/www/$ENV/drupal-config"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[ -f /etc/worxco/deploy-host-marker ] || fail "Must run on the deploy host"

# ============================================================
log "=== Drupal Cloud Remove (env=$ENV) ==="

# Verify FSx mounted (we need to wipe files there)
if ! mountpoint -q "/var/www/$ENV" 2>/dev/null; then
  log "FSx not mounted at /var/www/$ENV — skipping file removal"
else
  if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/vendor/bin/drush" ]; then
    log "Dropping all Drupal tables via drush sql:drop..."

    # drush sql:drop reads settings.php (env-var-driven), so set them up
    export ENVIRONMENT_NAME="$ENV"
    DRUPAL_DB_SECRET="worxco/$ENV/drupal/db-password"
    if RDS_ENDPOINT=$(aws ssm get-parameter --name "/$ENV/rds/endpoint" \
        --query 'Parameter.Value' --output text 2>/dev/null) && \
       DRUPAL_DB_PW=$(aws secretsmanager get-secret-value \
        --secret-id "$DRUPAL_DB_SECRET" \
        --query SecretString --output text 2>/dev/null); then
      export DRUPAL_DB_HOST="$RDS_ENDPOINT"
      export DRUPAL_DB_PORT="5432"
      export DRUPAL_DB_NAME="drupal"
      export DRUPAL_DB_USER="drupal_user"
      export DRUPAL_DB_PASS="$DRUPAL_DB_PW"
      (cd "$INSTALL_DIR" && vendor/bin/drush sql:drop -y) || \
        log "  drush sql:drop returned non-zero (DB may already be empty — continuing)"
    else
      log "  Could not resolve DB credentials — skipping sql:drop"
      log "  (You may need to drop tables manually with psql-env $ENV)"
    fi
  else
    log "No drush at $INSTALL_DIR/vendor/bin/drush — skipping sql:drop"
  fi

  if [ -d "$INSTALL_DIR" ]; then
    log "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || sudo rm -rf "$INSTALL_DIR"
  fi
  if [ -d "$CONFIG_DIR" ]; then
    log "Removing $CONFIG_DIR..."
    rm -rf "$CONFIG_DIR" 2>/dev/null || sudo rm -rf "$CONFIG_DIR"
  fi
fi

log ""
log "Done. Reinstall with: make install-drupal ENV=$ENV"
log ""
log "Preserved (intentional):"
log "  - /var/www/$ENV/drupal-private (hash_salt persists across reinstalls)"
log "  - drupal_user role in PostgreSQL"
log "  - Secrets Manager: worxco/$ENV/drupal/db-password"
log "  - Secrets Manager: worxco/$ENV/drupal/admin-password"
log ""
log "To wipe the preserved items too (rare):"
log "  rm -rf /var/www/$ENV/drupal-private"
log "  psql-env $ENV -c 'DROP USER drupal_user;'"
log "  aws secretsmanager delete-secret --secret-id worxco/$ENV/drupal/db-password --force-delete-without-recovery"
log "  aws secretsmanager delete-secret --secret-id worxco/$ENV/drupal/admin-password --force-delete-without-recovery"
