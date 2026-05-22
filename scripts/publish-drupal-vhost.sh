#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# publish-drupal-vhost: SSM-dispatch a one-shot write of
# /etc/nginx/shared/sites-enabled/drupal.conf to FSx via the deploy-host.
#
# Use this when:
#   - install-drupal already ran successfully (.installed marker exists)
#     but the nginx vhost is missing or out of date
#   - You want to update the vhost without doing a full reinstall
#
# After this, run `make reload-nginx ENV=<env>` to make the live fleet
# pick up the change.
#
# Usage: scripts/publish-drupal-vhost.sh <env>

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  echo "ERROR: deploy-host is not running." >&2
  exit 1
fi
echo "Deploy-host: $DEPLOY_ID"
echo "Publishing Drupal vhost for env=$ENV via SSM..."

INNER_SCRIPT=$(cat <<EOF_INNER
#!/bin/bash
set -euo pipefail
ENV="$ENV"

# Ensure /var/www is mounted (FSx) and current-env matches
ACTIVE=\$(cat /etc/worxco/current-env 2>/dev/null || echo NONE)
if [ "\$ACTIVE" != "\$ENV" ]; then
  echo "ERROR: deploy-host active env is '\$ACTIVE', not '\$ENV'." >&2
  echo "Run: sudo use-env \$ENV  (and retry)" >&2
  exit 1
fi
if ! mountpoint -q /var/www; then
  echo "ERROR: /var/www is not mounted (no FSx)." >&2
  exit 1
fi

SITE_NAME=\$(aws ssm get-parameter --name "/\$ENV/drupal/site-name" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "drupal-\$ENV.test")
INSTALL_DIR="/var/www/drupal"
NGINX_VHOST_DIR="/var/www/nginx/sites-enabled"

echo "Site name: \$SITE_NAME"
echo "Doc root:  \$INSTALL_DIR/web"
echo "Writing:   \$NGINX_VHOST_DIR/drupal.conf"

sudo mkdir -p "\$NGINX_VHOST_DIR"
sudo chmod 755 /var/www/nginx "\$NGINX_VHOST_DIR"

sudo tee "\$NGINX_VHOST_DIR/drupal.conf" > /dev/null <<NGINX_VHOST_EOF
# Drupal vhost — managed by scripts/publish-drupal-vhost.sh
#
# Routes by server_name (NOT default_server). The default_server lives in
# the baseline /etc/nginx/nginx.conf and is what handles ALB /health
# probes — that decouples nginx fleet health from Drupal install state.
# Two default_server declarations on the same listen port would be an
# nginx config error, so this vhost MUST NOT carry that flag.
server {
  listen 80;
  server_name \$SITE_NAME;
  root \$INSTALL_DIR/web;
  index index.php;

  access_log /var/log/nginx/drupal_access.log main;
  error_log  /var/log/nginx/drupal_error.log  warn;

  location / {
    try_files \\\$uri /index.php?\\\$query_string;
  }

  location ~ '\\\\.php\\\$|^/update.php' {
    fastcgi_split_path_info ^(.+?\\\\.php)(|/.*)\\\$;
    try_files \\\$fastcgi_script_name =404;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \\\$document_root\\\$fastcgi_script_name;
    fastcgi_param PATH_INFO       \\\$fastcgi_path_info;
    fastcgi_param HTTP_PROXY      "";
    fastcgi_pass  php83;
    fastcgi_intercept_errors on;
    fastcgi_request_buffering off;
    fastcgi_read_timeout 60s;
  }

  location ~ /\\\\..*/.*\\\\.php\\\$   { return 403; }
  location ~ ^/sites/.*/private/      { return 403; }
  location ~ /\\\\.(?!well-known)     { deny all; }

  # CSS/JS aggregates — Drupal 11 lazy-builds on demand. First request
  # must fall through to /index.php so Drupal can build the file.
  location ~ ^/sites/.*/files/(css|js)/ {
    try_files \\\$uri @rewrite;
    expires max;
    log_not_found off;
  }
  location ~ ^/sites/.*/files/styles/ {
    try_files \\\$uri @rewrite;
  }
  location @rewrite {
    rewrite ^ /index.php;
  }
}
NGINX_VHOST_EOF
sudo chmod 644 "\$NGINX_VHOST_DIR/drupal.conf"

echo "✓ Wrote vhost. Verify with:"
echo "  cat \$NGINX_VHOST_DIR/drupal.conf"
ls -la "\$NGINX_VHOST_DIR/drupal.conf"
EOF_INNER
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/publish-drupal-vhost.sh && bash /tmp/publish-drupal-vhost.sh\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

echo -n "Waiting"
for _ in $(seq 1 20); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "."; sleep 3 ;;
    *) echo " $STATUS."; break ;;
  esac
done

echo ""
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text

if [ "$STATUS" != "Success" ]; then
  echo "ERROR: status $STATUS" >&2
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi
echo ""
echo "✓ Drupal vhost published. Reload the fleet: make reload-nginx ENV=$ENV"
