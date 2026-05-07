#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/remove-drupal-local.sh
#
# Wipe the local Drupal install. Idempotent — safe to run when no
# install exists.
#
# Usage: bash scripts/deploy-host/remove-drupal-local.sh
#        (or: make remove-drupal-local)

set -euo pipefail

INSTALL_DIR="/var/www/local/drupal"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [ ! -d "$INSTALL_DIR" ]; then
  log "Nothing to remove ($INSTALL_DIR does not exist)"
  exit 0
fi

log "Removing $INSTALL_DIR..."
# Composer / drush sometimes write files with restrictive perms.
# Try as the running user first; fall back to sudo if needed.
if rm -rf "$INSTALL_DIR" 2>/dev/null; then
  log "Removed (no sudo needed)"
else
  log "Permission issue — retrying with sudo"
  sudo rm -rf "$INSTALL_DIR"
  log "Removed (sudo)"
fi

# Optionally clean up the parent /var/www/local if it's empty
if [ -d /var/www/local ] && [ -z "$(ls -A /var/www/local 2>/dev/null)" ]; then
  log "/var/www/local is empty — leaving it (will be reused by next install)"
fi

log "Done. To reinstall: make install-drupal-local"
