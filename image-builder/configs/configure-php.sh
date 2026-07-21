#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# Boot-time PHP-FPM configuration for Drupal-on-AWS.
#
# Runs once at instance boot (via systemd or cloud-init) BEFORE php*-fpm
# starts. Lives at /opt/worxco/configure-php.sh on each AMI; the AMI also
# carries /opt/worxco/php-version (just "8.3" or "7.4") so the same script
# works for both PHP versions.
#
# Sources of truth at boot:
#   - SSM /environment/name              -> ENV (e.g. "sandbox")
#   - SSM /<env>/fsx/dns-name            -> FSx mount target
#   - SSM /<env>/cache/{endpoint,port}   -> ElastiCache Valkey (TLS+AUTH)
#   - SSM /<env>/rds/{endpoint,port}     -> RDS endpoint for Drupal DB
#   - SSM /<env>/drupal/{db-name,db-user,site-name}
#   - Secrets Manager worxco/<env>/cache/auth-token   -> Valkey AUTH token
#   - Secrets Manager worxco/<env>/drupal/db-password -> Drupal DB password
#   - Secrets Manager /<env>/ses/smtp-credentials     -> SES relay creds
#
# Side effects:
#   - Mounts the FSx subtree /fsx/www at /var/www (NOT the FSx volume root;
#     PHP-FPM must not see /fsx/nginx — see docs/FSX-LAYOUT.md)
#   - Rewrites a managed BEGIN/END block inside /etc/php/$PHP_VER/fpm/pool.d/www.conf
#     containing env[...] (Drupal config) + php_value[...] (Valkey session) lines.
#     File ends up 640 root:www-data because it embeds the DB password and AUTH token.
#   - Configures Postfix SES relay (when credentials available)
#   - Starts php$PHP_VER-fpm and the health-check nginx (port 9100)
#
# Why mutate www.conf instead of using a pool.d/extra/*.conf drop-in?
#   PHP-FPM only accepts the `include=` directive at the GLOBAL level
#   (php-fpm.conf), not inside a pool section. The marker-block pattern
#   keeps everything inside [www] without touching the global config.

set -euo pipefail

# Read the PHP version baked into this AMI. Each PhpFpm{74,83}InstallComponent
# writes "7.4" or "8.3" here so this file is identical across both AMIs.
PHP_VER=$(cat /opt/worxco/php-version 2>/dev/null || echo "8.3")

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
ENV=$(aws ssm get-parameter --name "/environment/name" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "sandbox")

echo "[configure-php] Starting PHP $PHP_VER configuration for $ENV"

# ============================================================
# Mount the FSx /fsx/www subtree at /var/www. This MOUNT PATH (/var/www)
# is identical on every host (PHP fleet, nginx fleet, deploy-host) —
# env-awareness lives in WHICH FSx volume is mounted, not WHERE.
# Drupal sits at /var/www/drupal/web regardless of environment.
#
# Mount SOURCE is /fsx/www specifically — a sibling subtree of /fsx/nginx,
# not the FSx volume root. PHP-FPM workers must not have /fsx/nginx
# anywhere in their filesystem namespace. See docs/FSX-LAYOUT.md.
# ============================================================
FSX_DNS=$(aws ssm get-parameter --name "/$ENV/fsx/dns-name" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")
if [ -z "$FSX_DNS" ] || [ "$FSX_DNS" = "None" ]; then
  echo "[configure-php] FATAL: /$ENV/fsx/dns-name not set in SSM" >&2
  exit 1
fi
echo "[configure-php] Mounting $FSX_DNS:/fsx/www at /var/www"
if ! mount -t nfs4 -o vers=4.1,port=2049 "$FSX_DNS:/fsx/www" /var/www; then
  echo "[configure-php] FATAL: mount of $FSX_DNS:/fsx/www at /var/www failed" >&2
  exit 1
fi

# ============================================================
# Gather config from SSM and Secrets Manager
# ============================================================
WWW_CONF="/etc/php/$PHP_VER/fpm/pool.d/www.conf"

CACHE_ENDPOINT=$(aws ssm get-parameter --name "/$ENV/cache/endpoint" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")
CACHE_PORT=$(aws ssm get-parameter --name "/$ENV/cache/port" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "6380")
CACHE_AUTH_RAW=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/$ENV/cache/auth-token" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null || echo "")
CACHE_AUTH=$(echo "$CACHE_AUTH_RAW" | jq -r '.password // empty' 2>/dev/null || true)
[ -z "$CACHE_AUTH" ] && CACHE_AUTH="$CACHE_AUTH_RAW"
unset CACHE_AUTH_RAW

DRUPAL_DB_HOST=$(aws ssm get-parameter --name "/$ENV/rds/endpoint" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")
DRUPAL_DB_PORT=$(aws ssm get-parameter --name "/$ENV/rds/port" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "5432")
DRUPAL_DB_NAME=$(aws ssm get-parameter --name "/$ENV/drupal/db-name" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "drupal")
DRUPAL_DB_USER=$(aws ssm get-parameter --name "/$ENV/drupal/db-user" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "drupal_user")
DRUPAL_SITE_NAME=$(aws ssm get-parameter --name "/$ENV/drupal/site-name" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")
DRUPAL_DB_RAW=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/$ENV/drupal/db-password" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null || echo "")
DRUPAL_DB_PASS=$(echo "$DRUPAL_DB_RAW" | jq -r '.password // empty' 2>/dev/null || true)
[ -z "$DRUPAL_DB_PASS" ] && DRUPAL_DB_PASS="$DRUPAL_DB_RAW"
unset DRUPAL_DB_RAW

# hash_salt — env-var-based per docs/memory/salt-persistence-design.md.
# install-drupal.sh creates the secret on first install (and migrates
# from existing salt.txt on re-run for existing envs). If the secret
# doesn't exist yet, leave DRUPAL_HASH_SALT empty — settings.php falls
# back to file_get_contents('/var/www/drupal-private/salt.txt') during
# the file→SSM transition. Once every env has been migrated + verified,
# the file fallback (and this "if empty" tolerance) can go away.
DRUPAL_HASH_SALT=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/$ENV/drupal/hash-salt" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null || echo "")

# AWS_S3_BUCKET — this env's drupal-media bucket for flysystem_s3
# (see settings.php's $settings['flysystem'] block written by
# install-drupal.sh). Matches prod's convention: prod's Drupal reads
# getenv('AWS_S3_BUCKET') for the same purpose. Empty is tolerated
# — settings.php falls back to `${ENVIRONMENT_NAME}-drupal-media-kv-worxco`
# by naming convention, so a missing SSM param produces the right
# bucket name anyway.
AWS_S3_BUCKET=$(aws ssm get-parameter --name "/$ENV/s3/media-bucket" \
  --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null \
  || echo "")

# ============================================================
# Rewrite the BEGIN/END worxco-boot block inside www.conf.
# Idempotent: any prior block is stripped, the fresh one
# appended. Section [www] inherits these env[]/php_value[]
# directives directly because they're inside the pool body.
# ============================================================
if [ -n "$DRUPAL_DB_HOST" ] && [ "$DRUPAL_DB_HOST" != "None" ]; then
  echo "[configure-php] Writing boot-config block into $WWW_CONF"

  # Strip any existing managed block (if this is a reboot).
  sed -i '/^; BEGIN worxco-boot$/,/^; END worxco-boot$/d' "$WWW_CONF"

  # Append the fresh block. printf %s for values that may contain
  # $/backtick (DB password — cf-app-drupal ExcludeCharacters drops
  # quotes/@//#%&+:;=?[] but NOT $/backtick).
  {
    echo ""
    echo "; BEGIN worxco-boot"
    echo "; Generated by /opt/worxco/configure-php.sh at boot from SSM (/${ENV}/drupal/*,"
    echo "; /${ENV}/rds/*, /${ENV}/cache/*) and Secrets Manager (worxco/${ENV}/drupal/db-password,"
    echo "; worxco/${ENV}/cache/auth-token). DO NOT EDIT — regenerated on every boot."
    echo ";"
    echo "; Drupal env vars (read by settings.php via getenv())"
    # Quote every value. PHP-FPM's INI scanner rejects unquoted barewords
    # that contain shell-metacharacters like ~ ` * < > & — the cf-app-drupal
    # password generator can include any of those. We strip any embedded
    # double quote first so the resulting line stays well-formed.
    printf 'env[ENVIRONMENT_NAME] = "%s"\n' "${ENV//\"/}"
    printf 'env[DRUPAL_DB_HOST]   = "%s"\n' "${DRUPAL_DB_HOST//\"/}"
    printf 'env[DRUPAL_DB_PORT]   = "%s"\n' "${DRUPAL_DB_PORT//\"/}"
    printf 'env[DRUPAL_DB_NAME]   = "%s"\n' "${DRUPAL_DB_NAME//\"/}"
    printf 'env[DRUPAL_DB_USER]   = "%s"\n' "${DRUPAL_DB_USER//\"/}"
    printf 'env[DRUPAL_DB_PASS]   = "%s"\n' "${DRUPAL_DB_PASS//\"/}"
    printf 'env[DRUPAL_HASH_SALT] = "%s"\n' "${DRUPAL_HASH_SALT//\"/}"
    printf 'env[AWS_S3_BUCKET]    = "%s"\n' "${AWS_S3_BUCKET//\"/}"
    printf 'env[DRUPAL_SITE_NAME] = "%s"\n' "${DRUPAL_SITE_NAME//\"/}"
    if [ -n "$CACHE_ENDPOINT" ] && [ "$CACHE_ENDPOINT" != "None" ] && [ -n "$CACHE_AUTH" ]; then
      echo ";"
      echo "; Valkey session handler (TLS + AUTH; cf-cache TransitEncryptionEnabled=true)"
      echo 'php_value[session.save_handler] = redis'
      printf 'php_value[session.save_path]    = "tls://%s:%s?auth=%s&persistent=1"\n' \
        "$CACHE_ENDPOINT" "$CACHE_PORT" "$CACHE_AUTH"
    fi
    echo "; END worxco-boot"
  } >> "$WWW_CONF"

  # 0640 root:www-data — DB password and Valkey AUTH token are
  # embedded; default 0644 would be world-readable. PHP-FPM master
  # runs as root and reads pool config at startup, then drops to
  # www-data for workers (which inherit env without re-reading).
  chmod 640 "$WWW_CONF"
  chown root:www-data "$WWW_CONF"
else
  echo "[configure-php] WARNING: /$ENV/rds/endpoint not found - boot-config block NOT written"
fi

# ============================================================
# Postfix SES relay (when credentials are available)
# ============================================================
SES_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "/$ENV/ses/smtp-credentials" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null || echo "")
if [ -n "$SES_CREDS" ] && [ "$SES_CREDS" != "" ]; then
  SES_USER=$(echo "$SES_CREDS" | jq -r '.username // empty')
  SES_PASS=$(echo "$SES_CREDS" | jq -r '.password // empty')
  SES_HOST="email-smtp.$REGION.amazonaws.com"
  if [ -n "$SES_USER" ] && [ -n "$SES_PASS" ]; then
    echo "[configure-php] Configuring Postfix SES relay via $SES_HOST"
    postconf -e "relayhost = [$SES_HOST]:587"
    echo "[$SES_HOST]:587 $SES_USER:$SES_PASS" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
  fi
else
  echo "[configure-php] WARNING: SES credentials not found, Postfix will queue mail locally"
fi
systemctl restart postfix

# ============================================================
# (Re)start services so they pick up the marker block we just wrote
# ============================================================
# `restart` (not `start`) is critical: both services are systemd-enabled
# and were auto-started at boot BEFORE this script ran, against the
# AMI-baked www.conf with no marker block. A plain `start` is a no-op
# when the unit is already active, so workers would keep serving with
# the (cleared) environment from boot and getenv('DRUPAL_DB_HOST') etc.
# would return empty. `restart` forces master to re-read the file and
# fork fresh workers with the injected env[].
systemctl restart "php$PHP_VER-fpm"
echo "[configure-php] PHP-FPM $PHP_VER restarted"
systemctl restart nginx
echo "[configure-php] Health check NGINX restarted on port 9100"
