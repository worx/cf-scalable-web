#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# clear-drupal-cache: nuke Drupal caches in BOTH layers — the compiled
# service container on FSx AND the cache_* tables in PostgreSQL.
#
# Why both: Drupal's compiled service container has historically had
# wrong app_root or stale config from previous installs, and clearing
# only one layer leaves the other to repopulate the broken state on the
# next request. The 2026-05-15 debug arc burned hours on exactly this.
#
# Strategy: orchestrate via SSM to the deploy-host (which has FSx mounted
# at /var/www and DB credentials via psql-env). The active env on the
# deploy-host MUST match the requested env — refuses to run otherwise so
# we never accidentally wipe staging's cache while sandbox is active.
#
# Usage: scripts/clear-drupal-cache.sh <env>

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
  echo "ERROR: deploy-host is not running. Start it (make resume-deploy-host) and retry." >&2
  exit 1
fi
echo "Deploy-host: $DEPLOY_ID"
echo "Clearing Drupal caches for env=$ENV..."

# Build the actual inner script. Sent via base64 to dodge SSM JSON
# escaping hell — much cleaner than trying to inline-escape psql + sed.
INNER_SCRIPT=$(cat <<EOF_INNER
#!/bin/bash
set -e
ENV="$ENV"

ACTIVE=\$(cat /etc/worxco/current-env 2>/dev/null || echo NONE)
if [ "\$ACTIVE" != "\$ENV" ]; then
  echo "ERROR: deploy-host active env is '\$ACTIVE', not '\$ENV'." >&2
  echo "Run: sudo use-env \$ENV  (and try again)" >&2
  exit 1
fi
if ! mountpoint -q /var/www; then
  echo "ERROR: /var/www is not mounted (no FSx)." >&2
  exit 1
fi

echo "=== 1. Wipe compiled-container cache on FSx ==="
sudo rm -rf /var/www/drupal/web/sites/default/files/php/*
echo "  cleared /var/www/drupal/web/sites/default/files/php/"

echo "=== 2. TRUNCATE every cache_* table in the drupal DB ==="
# Build the table list dynamically so custom cache bins are caught too.
TABLES=\$(psql-env \$ENV -d drupal -tAc \\
  "SELECT string_agg(tablename, ', ') FROM pg_tables WHERE tablename LIKE 'cache_%';")
if [ -n "\$TABLES" ]; then
  echo "  Truncating: \$TABLES"
  psql-env \$ENV -d drupal -c "TRUNCATE TABLE \$TABLES;"
else
  echo "  no cache_* tables found (drupal DB empty?)"
fi

echo "=== 3. Done ==="
echo "Drupal will rebuild its compiled container on the next request."
echo "If PHP-FPM workers have stale OPcache, also run:"
echo "  make restart-php-fpm ENV=\$ENV"
EOF_INNER
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/clear-drupal-cache.sh && bash /tmp/clear-drupal-cache.sh\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

echo -n "Waiting for completion"
for _ in $(seq 1 30); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "."; sleep 3 ;;
    *) echo " $STATUS."; break ;;
  esac
done

echo ""
aws ssm list-command-invocations --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text

# Surface non-Success
STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
  --query "CommandInvocations[0].Status" --output text 2>/dev/null)
if [ "$STATUS" != "Success" ]; then
  echo ""
  echo "WARN: deploy-host command finished with status: $STATUS"
  exit 1
fi
