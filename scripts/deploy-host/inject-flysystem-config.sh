#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# inject-flysystem-config.sh — Add flysystem_s3 configuration block to a
# running Drupal installation's settings.php WITHOUT re-running the full
# install (which would drop the DB via `drush site:install`).
#
# Purpose: bridge the gap between "install-drupal.sh has been updated to
# write the flysystem block on fresh installs" and "existing sandbox/
# staging installs need the same block appended without destruction."
#
# Idempotent — BEGIN/END markers around the injected block. Re-running
# after the block is present is a no-op with a clear status message.
#
# Safety:
#   1. Backs up settings.php to .pre-flysystem-YYYYMMDD-HHMMSS before edit
#   2. Verifies php -l parses the file both BEFORE and AFTER the edit
#   3. Restores from backup automatically if post-edit parse fails
#   4. Never touches settings.php if it doesn't already exist
#
# Usage (from deploy-host, with env's FSx mounted via use-env):
#   sudo inject-flysystem-config.sh                    # /var/www/drupal
#   sudo inject-flysystem-config.sh /path/to/custom/settings.php
#
# Rollback: cp settings.php.pre-flysystem-<STAMP> settings.php
#
# Post-run steps to actually activate:
#   1. Confirm AWS_S3_BUCKET is exported in current env:
#        source /etc/worxco/envs/$(cat /etc/worxco/current-env) && echo $AWS_S3_BUCKET
#   2. PHP-FPM instances need env[AWS_S3_BUCKET] in their pool config
#      — either reboot compute (natural cycle) or SSM-push a one-off
#      pool.d addition + `systemctl reload php*-fpm`.
#

set -euo pipefail

SETTINGS_FILE="${1:-/var/www/drupal/web/sites/default/settings.php}"
MARKER_BEGIN="// BEGIN worxco-flysystem-s3 (managed by inject-flysystem-config.sh — do not edit)"
MARKER_END="// END worxco-flysystem-s3"

# ---------- preflight ----------
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "ERROR: settings.php not found at $SETTINGS_FILE" >&2
  echo "       Is the env's FSx mounted? Check with: mount | grep drupal" >&2
  exit 1
fi

if ! command -v php >/dev/null 2>&1; then
  echo "ERROR: 'php' not on PATH — cannot syntax-check settings.php." >&2
  exit 1
fi

# ---------- idempotency ----------
if grep -qF "$MARKER_BEGIN" "$SETTINGS_FILE"; then
  echo "OK: flysystem block already present in $SETTINGS_FILE"
  echo "    (marker '$MARKER_BEGIN' found — no change made)"
  exit 0
fi

# ---------- pre-edit syntax check ----------
if ! php -l "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "ERROR: $SETTINGS_FILE has PHP syntax errors BEFORE this script ran." >&2
  echo "       Refusing to edit a broken file. Fix the existing syntax first." >&2
  php -l "$SETTINGS_FILE" >&2
  exit 1
fi

# ---------- backup ----------
STAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP="${SETTINGS_FILE}.pre-flysystem-${STAMP}"
cp -p "$SETTINGS_FILE" "$BACKUP"
echo "Backup: $BACKUP"

# ---------- inject ----------
# Append (not insert-mid-file) — settings.php is order-tolerant for
# $settings[] assignments; late-loaded overrides win, which is the
# behavior we want here anyway.
cat >> "$SETTINGS_FILE" <<'FLYSYSTEM_EOF'

// BEGIN worxco-flysystem-s3 (managed by inject-flysystem-config.sh — do not edit)
// Registers the s3:// stream wrapper against a per-env S3 bucket.
// Bucket name comes from AWS_S3_BUCKET env var (set by refresh-env-config
// and configure-php.sh); PHP-side fallback derives from ENVIRONMENT_NAME
// so a missing env var lands on the right bucket rather than a wrong one.
// No 'key' / 'secret' — SDK uses the IAM instance role.
$_media_bucket = getenv('AWS_S3_BUCKET')
  ?: (getenv('ENVIRONMENT_NAME') . '-drupal-media-kv-worxco');
$settings['flysystem'] = [
  's3' => [
    'driver' => 's3',
    'config' => [
      'region' => getenv('AWS_S3_REGION') ?: 'us-east-1',
      'bucket' => $_media_bucket,
    ],
    'cache' => TRUE,
  ],
];
// END worxco-flysystem-s3
FLYSYSTEM_EOF

# ---------- post-edit syntax check + auto-rollback ----------
if ! php -l "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "ERROR: $SETTINGS_FILE has PHP syntax errors AFTER injection." >&2
  echo "       Auto-restoring from $BACKUP." >&2
  cp -p "$BACKUP" "$SETTINGS_FILE"
  php -l "$SETTINGS_FILE" >&2 || true
  exit 1
fi

echo "OK: flysystem block injected into $SETTINGS_FILE"
echo ""
echo "Next steps to activate:"
echo "  1. Confirm AWS_S3_BUCKET is populated for the current env:"
echo "       ENV=\$(cat /etc/worxco/current-env 2>/dev/null || echo sandbox)"
echo "       grep AWS_S3_BUCKET /etc/worxco/envs/\$ENV"
echo "  2. Get PHP-FPM instances to see env[AWS_S3_BUCKET]:"
echo "       - long-term: rebuild PHP-FPM AMI, cycle ASG"
echo "       - short-term: SSM add env[AWS_S3_BUCKET] to pool.d + reload FPM"
echo "  3. Verify from a PHP compute instance:"
echo "       sudo -u www-data php -r 'echo getenv(\"AWS_S3_BUCKET\") . PHP_EOL;'"
