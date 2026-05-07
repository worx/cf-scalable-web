#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/install-drupal-local.sh
#
# Local-only Drupal 11 install for fast iteration on the install logic.
# Uses SQLite + local disk on the deploy-host. No FSx, no RDS, no peering
# required. Once the install/remove cycle is validated, the cloud variant
# (install-drupal.sh) will reuse the validated logic with PostgreSQL/RDS
# and FSx-mounted /var/www/<env>/drupal.
#
# Usage: bash scripts/deploy-host/install-drupal-local.sh
#        (or: make install-drupal-local)
#
# Errors out if a marker file already exists. Use remove-drupal-local.sh
# to wipe a previous install.

set -euo pipefail

# ----- configuration -----
INSTALL_DIR="/var/www/local/drupal"
SQLITE_DIR="$INSTALL_DIR/sqlite"
SQLITE_FILE="$SQLITE_DIR/db.sqlite"
MARKER="$INSTALL_DIR/.installed"

ADMIN_USER="admin"
ADMIN_PASS="admin"
ADMIN_EMAIL="admin@drupal.local"
SITE_NAME="Drupal Local Test"

# ----- pretty logging -----
log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

# ----- pre-flight -----
if [ -f "$MARKER" ]; then
  echo ""
  echo "ERROR: Drupal already installed at $INSTALL_DIR"
  echo "Marker: $MARKER ($(cat "$MARKER" 2>/dev/null || echo 'unreadable'))"
  echo ""
  echo "To wipe and reinstall:  make reinstall-drupal-local"
  echo "To remove only:         make remove-drupal-local"
  exit 1
fi

log "=== Drupal Local Install Starting ==="

# Verify required tools are present
for tool in composer php sqlite3; do
  command -v "$tool" >/dev/null 2>&1 || \
    fail "$tool not found in PATH. Run scripts/deploy-host/bootstrap.sh first."
done

# Verify required PHP extensions
for ext in pdo_sqlite mbstring gd curl xml dom; do
  php -m | grep -qi "^${ext}$" || \
    fail "PHP extension '$ext' not loaded. Check apt installs in bootstrap.sh."
done

# Ensure /var/www/local exists and is writable by ubuntu
if [ ! -d /var/www/local ]; then
  log "Creating /var/www/local (sudo)"
  sudo mkdir -p /var/www/local
  sudo chown "$(id -u):$(id -g)" /var/www/local
fi

# ----- composer create-project (the slow step, ~2 min) -----
log "composer create-project drupal/recommended-project (~2 min, fetches Drupal core + deps)..."
composer create-project drupal/recommended-project "$INSTALL_DIR" --no-interaction

# ----- drush in the project -----
log "Adding drush/drush to the project..."
cd "$INSTALL_DIR"
composer require drush/drush --no-interaction

# ----- create SQLite directory -----
log "Creating SQLite directory at $SQLITE_DIR..."
mkdir -p "$SQLITE_DIR"

# ----- drush site:install -----
log "drush site:install standard (~1 min)..."
vendor/bin/drush site:install standard \
  --db-url="sqlite://localhost/$SQLITE_FILE" \
  --account-name="$ADMIN_USER" \
  --account-pass="$ADMIN_PASS" \
  --account-mail="$ADMIN_EMAIL" \
  --site-name="$SITE_NAME" \
  --yes

# ----- post-install verification -----
log "Verifying install via drush status..."
vendor/bin/drush status --fields=drupal-version,db-driver,db-status,bootstrap

# ----- marker -----
cat > "$MARKER" <<EOF
Installed at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Drupal core:  $(vendor/bin/drush status --field=drupal-version 2>/dev/null || echo 'unknown')
Mode:         local (SQLite)
Database:     $SQLITE_FILE
Admin user:   $ADMIN_USER
Admin pass:   $ADMIN_PASS
Admin email:  $ADMIN_EMAIL
EOF
chmod 644 "$MARKER"

log ""
log "============================================"
log "  Drupal Local Install Complete"
log "============================================"
log "  Location:  $INSTALL_DIR"
log "  Database:  $SQLITE_FILE"
log "  Admin:     $ADMIN_USER / $ADMIN_PASS"
log "  Marker:    $MARKER"
log ""
log "Validate:"
log "  cd $INSTALL_DIR && vendor/bin/drush status"
log "  cd $INSTALL_DIR && vendor/bin/drush user:information $ADMIN_USER"
log ""
log "Browser test (optional, deploy-host has no inbound port 8080 — needs SSH tunnel):"
log "  cd $INSTALL_DIR && vendor/bin/drush runserver 0.0.0.0:8080"
log ""
log "To wipe and start over: make reinstall-drupal-local"
