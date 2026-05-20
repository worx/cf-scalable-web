#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# init-fsx-layout: ensure the per-env FSx directory layout exists.
#
# Why this matters: nginx instances boot in cf-compute-nginx and try to
# mount $FSX:/fsx/nginx at /etc/nginx/shared. If /fsx/nginx doesn't
# exist on FSx yet (freshly-created volume, no one has populated the
# subdir tree), the mount fails, configure-nginx.sh bails on `set -e`
# BEFORE writing /etc/nginx/conf.d/upstream-php.conf, and nginx serves
# only the catch-all `server _`.
#
# This script SSM-dispatches to the deploy-host, mounts the env's FSx
# at /var/www (via use-env), and mkdirs the expected layout. Idempotent
# (mkdir -p), so safe to re-run.
#
# Run BEFORE cf-compute-nginx/cf-compute-php in any deploy that targets
# a freshly-created FSx volume.
#
# Usage: scripts/init-fsx-layout.sh <env>

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
  echo "ERROR: deploy-host is not running. Deploy it (make deploy-deploy-host) and retry." >&2
  exit 1
fi
echo "Deploy-host: $DEPLOY_ID"
echo "Initializing FSx layout for env=$ENV via SSM..."

INNER_SCRIPT=$(cat <<EOF_INNER
#!/bin/bash
set -euo pipefail
ENV="$ENV"

echo "=== 1. Wait for deploy-host bootstrap marker ==="
# Match install-drupal-remote.sh's pattern: wait up to 25 min for the
# UserData bootstrap to complete (in case this runs right after
# deploy-deploy-host).
for i in \$(seq 1 50); do
  if [ -f /etc/worxco/deploy-host-marker ] && command -v use-env >/dev/null 2>&1; then
    echo "  bootstrap complete"
    break
  fi
  echo "  still bootstrapping... attempt \$i/50"
  sleep 30
done
if [ ! -f /etc/worxco/deploy-host-marker ]; then
  echo "ERROR: bootstrap did not complete in 25 min" >&2
  exit 1
fi

echo "=== 2. Refresh env config + mount env's FSx ==="
sudo refresh-env-config "\$ENV"
sudo use-env "\$ENV"
if ! mountpoint -q /var/www; then
  echo "ERROR: /var/www not mounted after use-env" >&2
  exit 1
fi

echo "=== 3. Create expected FSx layout directories ==="
# These are the directories that downstream consumers (nginx ASG via
# /etc/nginx/shared mount, install-drupal.sh, future install-site)
# expect to find. mkdir -p is idempotent.

# nginx shared config tree — mounted by nginx instances at /etc/nginx/shared
sudo mkdir -p /var/www/nginx/sites-enabled
sudo chmod 755 /var/www/nginx /var/www/nginx/sites-enabled

# Multi-tenant site root — install-drupal-remote / install-site write here
sudo mkdir -p /var/www/sites
sudo chmod 755 /var/www/sites

echo "=== 4. Verify ==="
echo "  /var/www tree:"
sudo ls -la /var/www | head -20
echo ""
echo "  /var/www/nginx/sites-enabled/:"
sudo ls -la /var/www/nginx/sites-enabled/

echo ""
echo "✓ FSx layout initialized for env=\$ENV"
EOF_INNER
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/init-fsx-layout.sh && bash /tmp/init-fsx-layout.sh\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

echo -n "Waiting"
for _ in $(seq 1 60); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "."; sleep 5 ;;
    *) echo " $STATUS."; break ;;
  esac
done

echo ""
echo "--- Deploy-host output ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text

STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
  --query "CommandInvocations[0].Status" --output text 2>/dev/null)
if [ "$STATUS" != "Success" ]; then
  echo ""
  echo "ERROR: status $STATUS" >&2
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi
echo ""
echo "✓ init-fsx-layout: FSx layout initialized for env=$ENV"
