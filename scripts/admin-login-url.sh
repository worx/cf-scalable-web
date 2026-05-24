#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# admin-login-url: SSM-dispatch `drush user:login` (a.k.a. `drush uli`)
# on the deploy-host. Drush generates a one-time, time-limited login
# URL the operator can paste into a browser to land on the admin
# dashboard without knowing the admin password.
#
# Why this is the Drupal-native path: drush uli has been the canonical
# "I locked myself out / I want to skip password entry" mechanism in
# Drupal since the 7.x days. Anyone who's run Drupal at the CLI level
# reaches for it instinctively. Surfacing it via this Make target
# means operators don't have to remember the secret-fetch dance for
# routine "I want to log in" workflows.
#
# Usage: scripts/admin-login-url.sh <env>
#
# Side effect: the generated URL is single-use; clicking it logs you
# in once. Drush invalidates the token on use. Generates a fresh one
# every time this script runs.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# Resolve deploy-host instance + decide which URL prefix to embed in the
# drush-generated login URL.
#
# Prefer the public DNS name (https://<site-name>) when HTTPS is enabled
# for this env. Detection: compute-alb stack has AlbCertificateArn output
# iff DomainName was set at deploy time (per the HTTPS work). If HTTPS is
# off (env deployed with DomainName empty), fall back to http://<alb-dns>
# — the bare amazonaws.com name, which works but produces an ugly URL
# and a cert-mismatch warning if the operator manually adds https://.
DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  echo "ERROR: deploy-host not running." >&2
  exit 1
fi

ALB_STACK="cf-scalable-web-$ENV-compute-alb"
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "$ALB_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
  echo "ERROR: couldn't read ALB DNS from $ALB_STACK." >&2
  exit 1
fi

CERT_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$ALB_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AlbCertificateArn'].OutputValue" \
  --output text 2>/dev/null || true)
SITE_NAME=$(aws ssm get-parameter --name "/$ENV/drupal/site-name" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)

if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ] && \
   [ -n "$SITE_NAME" ] && [ "$SITE_NAME" != "None" ]; then
  DRUSH_URI="https://$SITE_NAME"
  echo "URI: $DRUSH_URI (HTTPS, public DNS)"
else
  DRUSH_URI="http://$ALB_DNS"
  echo "URI: $DRUSH_URI (HTTP fallback — env has no ACM cert)"
fi

echo "Generating one-time admin login URL via $DEPLOY_ID..."

# Build the inner script with values already expanded by THIS shell.
# All `$VAR` references below resolve here, not on the deploy-host —
# avoids inner-shell-expansion confusion (which previously caused drush
# to receive a literal `$ALB_DNS` and fall back to URI=localhost).
# `\$` survives intact for the few cases where we genuinely want the
# inner shell to expand at runtime (ACTIVE check, DRUPAL_DB_PASS).
INNER=$(cat <<EOF_INNER
#!/bin/bash
set -euo pipefail

# Refuse if deploy-host's active env doesn't match the requested env.
ACTIVE=\$(cat /etc/worxco/current-env 2>/dev/null || echo NONE)
if [ "\$ACTIVE" != "$ENV" ]; then
  echo "ERROR: deploy-host active env is '\$ACTIVE', not '$ENV'." >&2
  echo "Run: sudo use-env $ENV  (and retry)" >&2
  exit 1
fi
if ! mountpoint -q /var/www; then
  echo "ERROR: /var/www is not mounted." >&2
  exit 1
fi
if [ ! -f /var/www/drupal/.installed ]; then
  echo "ERROR: Drupal not installed for env=$ENV (no .installed marker)." >&2
  exit 1
fi

export HOME=/root
cd /var/www/drupal
source /etc/worxco/envs/$ENV
export DRUPAL_DB_PASS=\$(aws secretsmanager get-secret-value \\
  --secret-id "worxco/$ENV/drupal/db-password" \\
  --query SecretString --output text)

# --uri tells drush which hostname (and scheme) to embed in the generated
# URL. Pre-expanded at outer-shell time (no inner expansion) so drush
# gets the literal URL string. \$DRUSH_URI is set by the outer script to
# either https://<site-name> (when HTTPS is enabled) or http://<alb-dns>
# (HTTP fallback).
sudo -E HOME=/root vendor/bin/drush user:login --uri=$DRUSH_URI
EOF_INNER
)
B64=$(echo "$INNER" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d | bash\"]}" \
  --query 'Command.CommandId' --output text)

# Wait for completion (typically 2-3 sec — drush bootstrap + token gen)
for _ in $(seq 1 20); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Pending|InProgress) sleep 2 ;;
    *) break ;;
  esac
done

OUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text)

if [ "$STATUS" != "Success" ]; then
  echo "ERROR: drush command failed (status: $STATUS)" >&2
  echo "$OUT" >&2
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi

# Extract the URL drush printed. Format is typically:
#   http://<host>/user/reset/<uid>/<timestamp>/<hash>/login
URL=$(echo "$OUT" | grep -oE 'https?://[^ ]+/user/reset/[^ ]+' | head -1)
if [ -z "$URL" ]; then
  echo "WARN: drush succeeded but no login URL found in output. Raw:" >&2
  echo "$OUT" >&2
  exit 1
fi

echo ""
echo "One-time admin login URL (single-use, expires in 24h by default):"
echo ""
echo "  $URL"
echo ""
echo "Tip: paste into your browser. Lands you on the admin profile page;"
echo "from there, set a password if you want, or just navigate to /admin."
