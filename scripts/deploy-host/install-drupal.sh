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
# Environment robustness for non-interactive invocation
# ============================================================
# When this script is invoked via SSM RunShellScript (e.g., from
# scripts/install-drupal-remote.sh during make deploy-allX), it runs as
# root in a minimal shell where HOME is unset and composer refuses to run
# as root by default. Set both env vars before anything else so composer
# create-project / require work whether invoked interactively (ubuntu user
# with HOME=/home/ubuntu) or non-interactively (root, HOME missing).
export HOME="${HOME:-/root}"
export COMPOSER_ALLOW_SUPERUSER=1

# ============================================================
# Args + config
# ============================================================
ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: install-drupal.sh <env>"
  echo "Example: install-drupal.sh sandbox"
  exit 1
fi

# Paths are mount-target-relative — every host (deploy-host with use-env
# mounted, PHP fleet, nginx fleet) sees Drupal at /var/www/drupal regardless
# of which env is active. The deploy-host's `use-env <env>` mounts the
# target env's FSx at /var/www, so running install-drupal.sh after
# `use-env sandbox` installs into sandbox's FSx (visible to the runtime
# fleet at the same /var/www/drupal path).
INSTALL_DIR="/var/www/drupal"
PRIVATE_DIR="/var/www/drupal-private"
CONFIG_DIR="/var/www/drupal-config"
MARKER="$INSTALL_DIR/.installed"
SALT_FILE="$PRIVATE_DIR/salt.txt"

# Defaults (used when the cf-app-drupal stack is NOT deployed for this env).
# When cf-app-drupal IS deployed, these are overridden by the SSM parameters
# it owns (resolved a few lines below).
DB_NAME="drupal"
DB_USER="drupal_user"
DRUPAL_ADMIN_USER="admin"
SITE_NAME_DEFAULT="drupal-${ENV}.test"

# Where the secrets live in Secrets Manager. cf-app-drupal owns these
# when deployed. install-drupal auto-creates as a fallback if absent.
DRUPAL_DB_SECRET="worxco/$ENV/drupal/db-password"
DRUPAL_ADMIN_SECRET="worxco/$ENV/drupal/admin-password"

# Resolve config from SSM parameters if cf-app-drupal is deployed.
# Each lookup falls back to the local default on failure (parameter
# not found = stack not deployed = use defaults).
ssm_or() {
  # Args: parameter name, fallback value
  aws ssm get-parameter --name "$1" --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "$2"
}
DB_NAME=$(ssm_or "/$ENV/drupal/db-name" "$DB_NAME")
DB_USER=$(ssm_or "/$ENV/drupal/db-user" "$DB_USER")
DRUPAL_ADMIN_USER=$(ssm_or "/$ENV/drupal/admin-username" "$DRUPAL_ADMIN_USER")
SITE_NAME=$(ssm_or "/$ENV/drupal/site-name" "${DRUPAL_SITE_NAME:-$SITE_NAME_DEFAULT}")
ADMIN_EMAIL=$(ssm_or "/$ENV/drupal/admin-email" "admin@${SITE_NAME}")

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
# kept explicit for clearer failure modes). We also verify the active env
# matches what we're installing for, so the operator doesn't accidentally
# install sandbox's Drupal into staging's FSx (the new single-mount model
# makes this confusion possible).
if ! mountpoint -q /var/www 2>/dev/null; then
  fail "FSx not mounted at /var/www. Run: sudo use-env $ENV"
fi
ACTIVE_ENV=$(cat /etc/worxco/current-env 2>/dev/null || echo "NONE")
if [ "$ACTIVE_ENV" != "$ENV" ]; then
  fail "Active env is '$ACTIVE_ENV' but install requested for '$ENV'. Run: sudo use-env $ENV"
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
RDS_MASTER_RAW=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/$ENV/rds/master-password" \
  --query SecretString --output text 2>/dev/null) || \
  fail "Cannot read RDS master password. Is cf-database deployed for $ENV?"
# AWS-managed RDS master credentials are JSON: {"username":..., "password":...}
# Hand-created secrets are plaintext. Handle both.
RDS_MASTER_PW=$(echo "$RDS_MASTER_RAW" | jq -r '.password // empty' 2>/dev/null || true)
[ -z "$RDS_MASTER_PW" ] && RDS_MASTER_PW="$RDS_MASTER_RAW"
unset RDS_MASTER_RAW

# Drupal DB user password — read from Secrets Manager, generate if missing.
#
# Operational note: the cf-app-drupal CFN stack OWNS this secret (via
# GenerateSecretString) when deployed. Re-running install-drupal.sh after
# any cf-app-drupal deploy is REQUIRED so the postgres user's password
# gets re-ALTERed to match whatever value GenerateSecretString produced.
# Skipping this step is exactly how Drupal ended up with one password and
# the secret had another on 2026-05-15 — eventually fixed manually by
# rotating the secret + ALTER USER. The ALTER USER below makes the
# script safe to re-run any time the two might have diverged.
log "Resolving Drupal DB user password (Secrets Manager: $DRUPAL_DB_SECRET)..."
if DRUPAL_DB_RAW=$(aws secretsmanager get-secret-value \
    --secret-id "$DRUPAL_DB_SECRET" \
    --query SecretString --output text 2>/dev/null); then
  # Same JSON-or-plaintext defensive handling
  DRUPAL_DB_PW=$(echo "$DRUPAL_DB_RAW" | jq -r '.password // empty' 2>/dev/null || true)
  [ -z "$DRUPAL_DB_PW" ] && DRUPAL_DB_PW="$DRUPAL_DB_RAW"
  unset DRUPAL_DB_RAW
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
if DRUPAL_ADMIN_RAW=$(aws secretsmanager get-secret-value \
    --secret-id "$DRUPAL_ADMIN_SECRET" \
    --query SecretString --output text 2>/dev/null); then
  DRUPAL_ADMIN_PW=$(echo "$DRUPAL_ADMIN_RAW" | jq -r '.password // empty' 2>/dev/null || true)
  [ -z "$DRUPAL_ADMIN_PW" ] && DRUPAL_ADMIN_PW="$DRUPAL_ADMIN_RAW"
  unset DRUPAL_ADMIN_RAW
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

# Pass values to psql via `-v` and use `:'var'` / `:"var"` substitution
# inside the SQL. The heredoc terminator is single-quoted so bash does NO
# variable expansion on the body — psql handles the substitution and
# escapes values correctly (single quotes in values become '' automatically).
#
# This replaces the older un-quoted-heredoc form which interpolated bash
# vars directly into SQL. Bash's substitution itself is single-pass and
# does NOT re-evaluate metacharacters in the value (so `$` or backtick in
# the password did NOT actually cause shell injection), but the psql `-v`
# form is cleaner, less escaping-fragile (no `\$\$` dance), and the right
# pattern to copy for future SQL elsewhere.
PGPASSWORD="$RDS_MASTER_PW" psql -h "$RDS_ENDPOINT" -U dbadmin -d postgres \
  -v ON_ERROR_STOP=1 \
  -v db_user="$DB_USER" \
  -v drupal_db_pw="$DRUPAL_DB_PW" \
  -v db_name="$DB_NAME" \
  <<'EOF'
SELECT EXISTS (SELECT 1 FROM pg_user WHERE usename = :'db_user') AS user_exists \gset
\if :user_exists
  ALTER USER :"db_user" WITH PASSWORD :'drupal_db_pw';
  \echo Updated password for existing user
\else
  CREATE USER :"db_user" WITH PASSWORD :'drupal_db_pw';
  \echo Created user
\endif
GRANT ALL PRIVILEGES ON DATABASE :"db_name" TO :"db_user";
EOF

PGPASSWORD="$RDS_MASTER_PW" psql -h "$RDS_ENDPOINT" -U dbadmin -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -v db_user="$DB_USER" \
  -v db_name="$DB_NAME" \
  <<'EOF'
GRANT ALL ON SCHEMA public TO :"db_user";
ALTER SCHEMA public OWNER TO :"db_user";
ALTER DATABASE :"db_name" OWNER TO :"db_user";
EOF

# Don't keep master password lying around in the env
unset RDS_MASTER_PW

# ============================================================
step "Wipe any partial-install state in $INSTALL_DIR (no marker present)"
# ============================================================
# If a previous run failed mid-flight (e.g., composer create-project hit
# an env-var issue), $INSTALL_DIR has files but no .installed marker.
# composer create-project refuses to create into a non-empty directory,
# so we wipe it here. $PRIVATE_DIR's salt.txt is preserved intentionally
# — the later "Generate (or reuse) hash_salt" step is idempotent.
if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]; then
  log "$INSTALL_DIR has content but no marker — wiping for clean retry"
  sudo rm -rf "$INSTALL_DIR"/* "$INSTALL_DIR"/.[!.]* "$INSTALL_DIR"/..?* 2>/dev/null || true
fi

# ============================================================
step "Create directories on FSx (drupal/, drupal-private/, drupal-config/)"
# ============================================================
log "Ensuring $INSTALL_DIR (and siblings) writable by $(whoami)..."
sudo mkdir -p "$INSTALL_DIR" "$PRIVATE_DIR" "$CONFIG_DIR"
# Ownership: install user (ubuntu) for code, www-data group for read access
# from PHP-FPM workers on the runtime fleet. Sensitive files (salt.txt) get
# tightened later in this script.
sudo chown -R "$(id -u):www-data" \
  "$INSTALL_DIR" "$PRIVATE_DIR" "$CONFIG_DIR"
sudo chmod -R g+rX "$INSTALL_DIR" "$PRIVATE_DIR" "$CONFIG_DIR"

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
  # Mode 0640 with group www-data — settings.php reads this at request
  # time from PHP-FPM workers, which run as www-data. The earlier
  # `chmod 600` shut PHP-FPM out (root-only), caused Drupal to log
  # "Missing $settings['hash_salt']" and return HTTP 500 on every
  # request. Spec lives in docs/FSX-LAYOUT.md "File ownership and
  # permissions" — keep this in sync with that doc.
  chown root:www-data "$SALT_FILE"
  chmod 0640 "$SALT_FILE"
else
  log "Reusing existing hash_salt at $SALT_FILE"
fi

# ============================================================
step "drush site:install standard (~1 min)"
# ============================================================
# Pass the password raw in --db-url. cf-app-drupal's GenerateSecretString
# ExcludeCharacters already excludes every character that would actually
# need URL encoding in userinfo per RFC 3986: @ : / ? # % [ ] etc. The
# remaining permitted characters (alphanumeric + ' , . - _) are all valid
# unreserved or sub-delim characters in URL userinfo and need no encoding.
#
# Diagnosed 2026-05-19: earlier "defense in depth" Python url-quote step
# (commit a52e38a) was actually CAUSING the bug — Python's
# urllib.parse.quote(safe='') aggressively percent-encodes everything
# outside [A-Za-z0-9_.-~], and drush 13.7's URL parser doesn't decode all
# of those back symmetrically. The fix is to not encode at all.
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

// Paths on FSx — no env prefix (post-cutover commit ee319d5; the env's
// FSx is mounted at /var/www on every host that needs it, so the env name
// isn't in the path).
$_salt = '/var/www/drupal-private/salt.txt';
$settings['hash_salt'] = is_readable($_salt) ? trim(file_get_contents($_salt)) : '';

// Files
$settings['file_public_path']      = 'sites/default/files';
$settings['file_private_path']     = '/var/www/drupal-private';
$settings['config_sync_directory'] = '/var/www/drupal-config';

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
step "Make Drupal-writable directories accessible to PHP-FPM (www-data)"
# ============================================================
# Drupal writes to several directories at runtime:
#   - public files (sites/default/files/): CSS/JS aggregates, image styles,
#     user-uploaded files
#   - private files ($PRIVATE_DIR): Drupal's "private://" file system
#   - config sync ($CONFIG_DIR): Drupal's defensive .htaccess writes here
# These get created as root:root during composer create-project + drush
# site:install (since this script runs as root via SSM dispatch). Without
# this final pass, PHP-FPM workers (running as www-data) can't write —
# CSS aggregation fails (URLs 404), .htaccess writes fail (security
# warnings in watchdog).
# Spec is in docs/FSX-LAYOUT.md "File ownership and permissions".
for d in "$INSTALL_DIR/web/sites/default/files" "$PRIVATE_DIR" "$CONFIG_DIR"; do
  if [ -d "$d" ]; then
    sudo chown -R root:www-data "$d"
    # u=rwX,g=rwX,o= → owner+group r/w + traverse, other locked out.
    # Capital X applies execute only to dirs (not files), keeping
    # individual files at 0660 (read/write for owner+group only).
    sudo chmod -R u=rwX,g=rwX,o= "$d"
    log "  permissions set on $d (root:www-data, g+rwX)"
  fi
done
# salt.txt stays the tighter 0640 (no group-write) since it's a secret.
[ -f "$SALT_FILE" ] && sudo chmod 0640 "$SALT_FILE"

# ============================================================
step "Publish Drupal nginx vhost to FSx (read by all nginx instances)"
# ============================================================
# nginx hosts mount $FSX:/fsx/nginx at /etc/nginx/shared and include
# /etc/nginx/shared/sites-enabled/*.conf. From the deploy-host's
# perspective (FSx mounted at /var/www), that path is
# /var/www/nginx/sites-enabled/. Writing the vhost here makes it
# visible to every nginx instance immediately via NFS; a separate
# `make reload-nginx ENV=<env>` SSM-reloads the running workers.
NGINX_VHOST_DIR="/var/www/nginx/sites-enabled"
sudo mkdir -p "$NGINX_VHOST_DIR"
sudo chmod 755 /var/www/nginx "$NGINX_VHOST_DIR"

sudo tee "$NGINX_VHOST_DIR/drupal.conf" > /dev/null <<NGINX_VHOST_EOF
# Drupal vhost — managed by scripts/deploy-host/install-drupal.sh
# Path on FSx:    /fsx/nginx/sites-enabled/drupal.conf
# Path on nginx:  /etc/nginx/shared/sites-enabled/drupal.conf
# Reload after edit: make reload-nginx ENV=$ENV

server {
  # default_server: this vhost handles requests for $SITE_NAME AND any
  # unknown Host header (e.g., the ALB DNS, EC2 internal hostnames).
  # Without default_server, an unknown Host would fall through to
  # /etc/nginx/conf.d/health-check.conf or nginx's implicit default
  # and return 404. See docs/memory/gotchas.md.
  listen 80 default_server;
  server_name $SITE_NAME;
  root $INSTALL_DIR/web;
  index index.php;

  access_log /var/log/nginx/drupal_access.log main;
  error_log  /var/log/nginx/drupal_error.log  warn;

  # ALB target-group health check probes here. Returning 200 lets the
  # ALB consider this nginx target healthy. Kept on port 80 (rather
  # than a separate /etc/nginx/conf.d/health-check.conf with its own
  # default_server) so it doesn't fight for default_server status.
  location = /health {
    access_log off;
    return 200 'OK';
    add_header Content-Type text/plain;
  }

  # Drupal: try static file, fall back to index.php
  location / {
    try_files \$uri /index.php?\$query_string;
  }

  # PHP via FastCGI to PHP 8.3 upstream (defined in /etc/nginx/conf.d/upstream-php.conf)
  location ~ '\\.php\$|^/update.php' {
    fastcgi_split_path_info ^(.+?\\.php)(|/.*)\$;
    try_files \$fastcgi_script_name =404;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO       \$fastcgi_path_info;
    fastcgi_param HTTP_PROXY      "";
    fastcgi_pass  php83;
    fastcgi_intercept_errors on;
    fastcgi_request_buffering off;
    fastcgi_read_timeout 60s;
  }

  # Drupal security: block PHP under dotted paths and private files
  location ~ /\\..*/.*\\.php\$    { return 403; }
  location ~ ^/sites/.*/private/ { return 403; }
  location ~ /\\.(?!well-known)  { deny all; }

  # CSS/JS aggregates — Drupal 11 lazy-builds these on demand via PHP,
  # so the URL is generated BEFORE the file exists on disk. The first
  # request must fall through to /index.php (via @rewrite) so Drupal
  # can build + cache the aggregate. Subsequent requests are served
  # as static files (nginx's default for matching URIs). Without
  # try_files here, nginx 404s every aggregate URL and the page
  # renders unstyled.
  location ~ ^/sites/.*/files/(css|js)/ {
    try_files \$uri @rewrite;
    expires max;
    log_not_found off;
  }
  location ~ ^/sites/.*/files/styles/ {
    try_files \$uri @rewrite;
  }
  location @rewrite {
    rewrite ^ /index.php;
  }
}
NGINX_VHOST_EOF
sudo chmod 644 "$NGINX_VHOST_DIR/drupal.conf"
log "  wrote $NGINX_VHOST_DIR/drupal.conf"

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
