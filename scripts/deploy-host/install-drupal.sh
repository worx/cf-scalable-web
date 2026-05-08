#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/install-drupal.sh
#
# Install Drupal 11 against the cloud data plane: PostgreSQL on RDS,
# code on FSx OpenZFS, sessions/cache on Valkey (added later). This is
# the production install path. For fast iteration on the install logic
# itself, see install-drupal-local.sh (SQLite + local disk).
#
# Usage: bash scripts/deploy-host/install-drupal.sh <env>
#        (or: make install-drupal ENV=sandbox)
#
# Prerequisites:
#   - cf-vpc, cf-iam, cf-storage, cf-database, cf-cache deployed for <env>
#   - cf-deploy-peering deployed for <env>
#   - FSx mounted at /var/www/<env>/  (run: sudo mount-env <env>)
#   - /etc/hosts has the FSx entry  (run: sudo refresh-env-config <env>)
#
# Errors out if the install marker exists for <env>. Use remove-drupal.sh
# (or `make reinstall-drupal ENV=<env>`) to wipe a previous install.
#

set -euo pipefail

# ============================================================
# Args + config
# ============================================================
ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: install-drupal.sh <env>"
  echo "Example: install-drupal.sh sandbox"
  exit 1
fi

INSTALL_DIR="/var/www/$ENV/drupal"
PRIVATE_DIR="/var/www/$ENV/drupal-private"
CONFIG_DIR="/var/www/$ENV/drupal-config"
MARKER="$INSTALL_DIR/.installed"
SALT_FILE="$PRIVATE_DIR/salt.txt"

DB_NAME="drupal"
DB_USER="drupal_user"
DRUPAL_ADMIN_USER="admin"

# Where the secrets live in Secrets Manager. The install script
# auto-creates these on first run if they don't exist; the upcoming
# cf-app-drupal.yaml stack (Phase C step 3) will create them
# explicitly with the proper retention/rotation policies.
DRUPAL_DB_SECRET="worxco/$ENV/drupal/db-password"
DRUPAL_ADMIN_SECRET="worxco/$ENV/drupal/admin-password"

# Default site name — override with: DRUPAL_SITE_NAME=mysite.test bash install-drupal.sh ...
SITE_NAME="${DRUPAL_SITE_NAME:-drupal-${ENV}.test}"
ADMIN_EMAIL="admin@${SITE_NAME}"

# ============================================================
# Pretty logging
# ============================================================
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

step() {
  echo ""
  echo "============================================"
  echo "STEP: $*"
  echo "============================================"
}

# ============================================================
# Pre-flight
# ============================================================
[ -f /etc/worxco/deploy-host-marker ] || fail "Must run on the deploy host"

if [ -f "$MARKER" ]; then
  echo ""
  echo "ERROR: Drupal already installed for env '$ENV' at $INSTALL_DIR"
  echo "Marker:  $MARKER"
  echo ""
  echo "To wipe and reinstall:  make reinstall-drupal ENV=$ENV"
  echo "To remove only:         make remove-drupal ENV=$ENV"
  exit 1
fi

# Verify FSx is mounted (we don't auto-mount — it's a separate concern,
# kept explicit for clearer failure modes).
if ! mountpoint -q "/var/www/$ENV" 2>/dev/null; then
  fail "FSx not mounted at /var/www/$ENV. Run: sudo mount-env $ENV"
fi

# Verify required tools
for tool in composer php psql openssl aws; do
  command -v "$tool" >/dev/null 2>&1 || \
    fail "$tool not found in PATH. Run scripts/deploy-host/bootstrap.sh first."
done

# Verify required PHP extensions
for ext in pdo_pgsql mbstring gd curl xml dom; do
  php -m | grep -qi "^${ext}$" || \
    fail "PHP extension '$ext' not loaded. Check apt installs in bootstrap.sh."
done

# Verify network connectivity to RDS (peering working?)
RDS_ENDPOINT=$(aws ssm get-parameter --name "/$ENV/rds/endpoint" \
  --query 'Parameter.Value' --output text 2>/dev/null) || \
  fail "Cannot read /$ENV/rds/endpoint from SSM. Is cf-database deployed?"
nc -zv "$RDS_ENDPOINT" 5432 2>&1 | grep -q succeeded || \
  fail "Cannot reach RDS at $RDS_ENDPOINT:5432. Is cf-deploy-peering deployed?"

step "Drupal Cloud Install Starting (env=$ENV)"

# ============================================================
step "Fetch credentials (RDS master + create/read Drupal secrets)"
# ============================================================
log "Reading RDS master password from worxco/$ENV/rds/master-password..."
RDS_MASTER_PW=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/$ENV/rds/master-password" \
  --query SecretString --output text 2>/dev/null) || \
  fail "Cannot read RDS master password. Is cf-database deployed for $ENV?"

# Drupal DB user password — read from Secrets Manager, generate if missing
log "Resolving Drupal DB user password (Secrets Manager: $DRUPAL_DB_SECRET)..."
if DRUPAL_DB_PW=$(aws secretsmanager get-secret-value \
    --secret-id "$DRUPAL_DB_SECRET" \
    --query SecretString --output text 2>/dev/null); then
  log "  Using existing password from Secrets Manager"
else
  log "  Secret not found — generating new password and storing"
  DRUPAL_DB_PW=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  aws secretsmanager create-secret \
    --name "$DRUPAL_DB_SECRET" \
    --description "Drupal DB user password for env $ENV" \
    --secret-string "$DRUPAL_DB_PW" \
    --tags Key=Environment,Value="$ENV" Key=Application,Value=drupal \
    >/dev/null
  log "  Created secret $DRUPAL_DB_SECRET"
fi

# Drupal admin password — same pattern
log "Resolving Drupal admin password (Secrets Manager: $DRUPAL_ADMIN_SECRET)..."
if DRUPAL_ADMIN_PW=$(aws secretsmanager get-secret-value \
    --secret-id "$DRUPAL_ADMIN_SECRET" \
    --query SecretString --output text 2>/dev/null); then
  log "  Using existing admin password from Secrets Manager"
else
  log "  Secret not found — generating new admin password and storing"
  DRUPAL_ADMIN_PW=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)
  aws secretsmanager create-secret \
    --name "$DRUPAL_ADMIN_SECRET" \
    --description "Drupal admin password for env $ENV" \
    --secret-string "$DRUPAL_ADMIN_PW" \
    --tags Key=Environment,Value="$ENV" Key=Application,Value=drupal \
    >/dev/null
  log "  Created secret $DRUPAL_ADMIN_SECRET"
fi

# ============================================================
step "Create $DB_USER in PostgreSQL and grant access to '$DB_NAME'"
# ============================================================
# Idempotent: CREATE-or-ALTER inside a DO block. Then transfer ownership
# of the database to drupal_user so it can CREATE TABLE / INDEX.
log "Connecting as RDS master (dbadmin) to create user and grant privileges..."
PGPASSWORD="$RDS_MASTER_PW" psql -h "$RDS_ENDPOINT" -U dbadmin -d postgres \
  -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$DB_USER') THEN
    CREATE USER $DB_USER WITH PASSWORD '$DRUPAL_DB_PW';
    RAISE NOTICE 'Created user $DB_USER';
  ELSE
    ALTER USER $DB_USER WITH PASSWORD '$DRUPAL_DB_PW';
    RAISE NOTICE 'Updated password for existing user $DB_USER';
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

PGPASSWORD="$RDS_MASTER_PW" psql -h "$RDS_ENDPOINT" -U dbadmin -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 <<EOF
GRANT ALL ON SCHEMA public TO $DB_USER;
ALTER SCHEMA public OWNER TO $DB_USER;
ALTER DATABASE $DB_NAME OWNER TO $DB_USER;
EOF

# Don't keep master password lying around in the env
unset RDS_MASTER_PW

# ============================================================
step "Create directories on FSx (drupal/, drupal-private/, drupal-config/)"
# ============================================================
log "Ensuring /var/www/$ENV is writable by $(whoami)..."
sudo mkdir -p "$INSTALL_DIR" "$PRIVATE_DIR" "$CONFIG_DIR"
sudo chown -R "$(id -u):$(id -g)" \
  "$INSTALL_DIR" "$PRIVATE_DIR" "$CONFIG_DIR"

# ============================================================
step "composer create-project drupal/recommended-project (~2 min)"
# ============================================================
export COMPOSER_MEMORY_LIMIT=-1
START_TS=$(date +%s)
composer create-project drupal/recommended-project "$INSTALL_DIR" \
  --no-interaction --no-progress --prefer-dist
log "  composer create-project finished in $(( $(date +%s) - START_TS ))s"

# ============================================================
step "composer require drush/drush (project-local)"
# ============================================================
cd "$INSTALL_DIR"
composer require drush/drush --no-interaction --no-progress

# ============================================================
step "Generate (or reuse) hash_salt — persists across reinstalls"
# ============================================================
if [ ! -f "$SALT_FILE" ]; then
  log "Generating new hash_salt at $SALT_FILE"
  php -r "echo bin2hex(random_bytes(32));" > "$SALT_FILE"
  chmod 600 "$SALT_FILE"
else
  log "Reusing existing hash_salt at $SALT_FILE"
fi

# ============================================================
step "drush site:install standard (~1 min)"
# ============================================================
vendor/bin/drush site:install standard \
  --db-url="pgsql://$DB_USER:$DRUPAL_DB_PW@$RDS_ENDPOINT/$DB_NAME" \
  --account-name="$DRUPAL_ADMIN_USER" \
  --account-pass="$DRUPAL_ADMIN_PW" \
  --account-mail="$ADMIN_EMAIL" \
  --site-name="$SITE_NAME" \
  --yes

# ============================================================
step "Replace settings.php with env-var-driven config"
# ============================================================
# drush wrote a static settings.php with the install-time DB credentials.
# We replace it with one that reads from environment variables, so:
#   - PHP-FPM instances (with their boot-script-injected env vars) work
#   - drush from the deploy host works (we export the same vars below)
#   - secrets are never committed into FSx files
#
# The PHP-FPM boot script extension is a separate concern (covered by
# docs/plans/drupal-install.md, "Boot Script Integration" section).
SETTINGS_FILE="$INSTALL_DIR/web/sites/default/settings.php"
chmod u+w "$INSTALL_DIR/web/sites/default" "$SETTINGS_FILE"

cat > "$SETTINGS_FILE" <<'SETTINGS_EOF'
<?php
// SPDX-License-Identifier: GPL-2.0-or-later
// Generated by scripts/deploy-host/install-drupal.sh — env-var-driven config.

$_env = getenv('ENVIRONMENT_NAME') ?: 'sandbox';

$databases['default']['default'] = [
  'driver'   => 'pgsql',
  'host'     => getenv('DRUPAL_DB_HOST') ?: 'localhost',
  'port'     => getenv('DRUPAL_DB_PORT') ?: '5432',
  'database' => getenv('DRUPAL_DB_NAME') ?: 'drupal',
  'username' => getenv('DRUPAL_DB_USER') ?: 'drupal_user',
  'password' => getenv('DRUPAL_DB_PASS') ?: '',
  'prefix'   => '',
];

// hash_salt is a per-environment file on FSx (persists across reinstalls
// to avoid invalidating sessions when the codebase is reinstalled).
$_salt = '/var/www/' . $_env . '/drupal-private/salt.txt';
$settings['hash_salt'] = is_readable($_salt) ? trim(file_get_contents($_salt)) : '';

// Files
$settings['file_public_path']    = 'sites/default/files';
$settings['file_private_path']   = '/var/www/' . $_env . '/drupal-private';
$settings['config_sync_directory'] = '/var/www/' . $_env . '/drupal-config';

// Trusted hosts. ALB DNS pattern is permissive for sandbox/staging;
// production should tighten this to a specific ALB DNS or domain.
$settings['trusted_host_patterns'] = [
  '^localhost$',
  '^127\.0\.0\.1$',
  '^.+\.elb\.amazonaws\.com$',
];
if ($_name = getenv('DRUPAL_SITE_NAME')) {
  $settings['trusted_host_patterns'][] = '^' . preg_quote($_name) . '$';
}

// Optional: include a per-env override file if one exists alongside this.
// $local = __DIR__ . '/settings.local.php';
// if (file_exists($local)) { include $local; }
SETTINGS_EOF

chmod 444 "$SETTINGS_FILE"
chmod 555 "$INSTALL_DIR/web/sites/default"

# ============================================================
step "Verify install via drush (with env vars set so settings.php works)"
# ============================================================
export ENVIRONMENT_NAME="$ENV"
export DRUPAL_DB_HOST="$RDS_ENDPOINT"
export DRUPAL_DB_PORT="5432"
export DRUPAL_DB_NAME="$DB_NAME"
export DRUPAL_DB_USER="$DB_USER"
export DRUPAL_DB_PASS="$DRUPAL_DB_PW"
export DRUPAL_SITE_NAME="$SITE_NAME"

vendor/bin/drush status \
  --fields=drupal-version,db-driver,db-status,bootstrap,uri,php-version

# ============================================================
step "Drop install marker"
# ============================================================
cat > "$MARKER" <<MARKER_EOF
Installed at:    $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Drupal core:     $(vendor/bin/drush status --field=drupal-version 2>/dev/null || echo 'unknown')
Mode:            cloud (RDS + FSx)
Environment:     $ENV
Path:            $INSTALL_DIR
DB endpoint:     $RDS_ENDPOINT
DB name:         $DB_NAME
DB user:         $DB_USER
DB password:     stored in Secrets Manager: $DRUPAL_DB_SECRET
Site name:       $SITE_NAME
Admin user:      $DRUPAL_ADMIN_USER
Admin password:  stored in Secrets Manager: $DRUPAL_ADMIN_SECRET
MARKER_EOF
chmod 644 "$MARKER"

log ""
log "============================================"
log "  Drupal Cloud Install Complete (env=$ENV)"
log "============================================"
log "  Path:        $INSTALL_DIR  (on FSx)"
log "  DB:          $DB_NAME on $RDS_ENDPOINT"
log "  Site name:   $SITE_NAME"
log "  Admin user:  $DRUPAL_ADMIN_USER"
log "  Admin pass:  see Secrets Manager: $DRUPAL_ADMIN_SECRET"
log ""
log "  Read admin password:"
log "    aws secretsmanager get-secret-value \\"
log "      --secret-id $DRUPAL_ADMIN_SECRET \\"
log "      --query SecretString --output text"
log ""
log "Browser preview via drush rs (deploy host has no inbound 8080):"
log "  source /etc/worxco/envs/$ENV"
log "  export DRUPAL_DB_PASS=\"\$(aws secretsmanager get-secret-value \\"
log "    --secret-id $DRUPAL_DB_SECRET --query SecretString --output text)\""
log "  cd $INSTALL_DIR && vendor/bin/drush runserver 0.0.0.0:8080"
log "  # Then: ssh -L 8080:localhost:8080 deploy-host"
log ""
log "Production traffic (via ALB) requires the PHP-FPM boot script to set"
log "the same DRUPAL_DB_* env vars from SSM/Secrets at instance start."
log "See: docs/plans/drupal-install.md, 'Boot Script Integration'"
