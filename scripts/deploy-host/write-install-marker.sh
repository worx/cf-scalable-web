#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/write-install-marker.sh
#
# Purpose:  Write /var/www/drupal/.installed with informational metadata
#           about the current Drupal deployment (install date, Drupal
#           version, DB endpoint, secret paths, admin location).
#
#           Post-refactor to structural correctness checks (commit 308bdd5,
#           see docs/memory/structural-checks-over-markers.md), NO
#           operation depends on this file's existence — it is purely
#           informational. But the content remains useful when SSH'd in
#           and asking "when was this installed?" / "which RDS?" / "where
#           are the secrets?"
#
# Usage:    sudo scripts/deploy-host/write-install-marker.sh <env>
#
# Called from:
#   - scripts/deploy-host/install-drupal.sh (at end of a fresh install)
#   - `make create-installed ENV=<env>` (backfill or refresh existing)
#
# Preconditions:
#   - Running as root (needs to chown the marker to www-data)
#   - /var/www is mounted (env's FSx via use-env)
#   - Drupal is deployed at /var/www/drupal (drush + settings.php present)
#   - SSM parameter /<env>/rds/endpoint exists (for RDS endpoint lookup)
#
# Idempotent: safe to re-run. Overwrites any existing marker with a
# fresh snapshot of the deployment's current metadata.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (needs to chown the marker to www-data)" >&2
  exit 1
fi

if ! mountpoint -q /var/www; then
  echo "ERROR: /var/www is not mounted. Run: sudo use-env $ENV" >&2
  exit 1
fi

DRUPAL_DIR=/var/www/drupal
MARKER="$DRUPAL_DIR/.installed"

if [ ! -x "$DRUPAL_DIR/vendor/bin/drush" ] \
   || [ ! -f "$DRUPAL_DIR/web/sites/default/settings.php" ]; then
  echo "ERROR: Drupal not deployed at $DRUPAL_DIR (missing drush and/or settings.php)" >&2
  echo "       Run: make install-drupal ENV=$ENV" >&2
  exit 1
fi

# Data collection — non-fatal on any single lookup (partial info is fine).
RDS_ENDPOINT=$(aws ssm get-parameter --name "/$ENV/rds/endpoint" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo 'unknown')
SETTINGS_MTIME=$(stat -c %y "$DRUPAL_DIR/web/sites/default/settings.php" 2>/dev/null \
  | cut -d' ' -f1-2 | cut -d'.' -f1 || echo 'unknown')
DRUPAL_VERSION=$(cd "$DRUPAL_DIR" && vendor/bin/drush status --field=drupal-version 2>/dev/null || echo 'unknown')
NOW_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Site name matches the cf-app-drupal DNS convention.
SITE_NAME="drupal-${ENV}.test"

DB_NAME="drupal"
DB_USER="drupal_user"
DRUPAL_DB_SECRET="worxco/$ENV/drupal/db-password"
DRUPAL_ADMIN_SECRET="worxco/$ENV/drupal/admin-password"

cat > "$MARKER" <<MARKER_EOF
Marker written at:  $NOW_UTC
Install date proxy: settings.php mtime = $SETTINGS_MTIME
Drupal core:        $DRUPAL_VERSION
Mode:               cloud (RDS + FSx)
Environment:        $ENV
Path:               $DRUPAL_DIR
DB endpoint:        $RDS_ENDPOINT
DB name:            $DB_NAME
DB user:            $DB_USER
DB password:        stored in Secrets Manager: $DRUPAL_DB_SECRET
Site name:          $SITE_NAME
Admin user:         admin
Admin password:     stored in Secrets Manager: $DRUPAL_ADMIN_SECRET
MARKER_EOF

chown www-data:www-data "$MARKER"
chmod 644 "$MARKER"

echo "OK: wrote $MARKER (chown www-data:www-data, chmod 644)"
