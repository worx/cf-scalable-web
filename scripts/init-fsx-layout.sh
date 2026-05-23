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

echo "=== 2. Refresh env config (resolves FSX_DNS from SSM into /etc/worxco/envs/\$ENV) ==="
sudo refresh-env-config "\$ENV"
# Source the env file to get FSX_DNS into this shell.
# shellcheck disable=SC1090
source "/etc/worxco/envs/\$ENV"
if [ -z "\${FSX_DNS:-}" ]; then
  echo "ERROR: FSX_DNS not in /etc/worxco/envs/\$ENV after refresh" >&2
  exit 1
fi

echo "=== 3. Temporary root-mount of FSx to bootstrap the sibling subtree layout ==="
# Why a temporary root mount instead of using use-env:
#   use-env mounts /fsx/www and /fsx/nginx as SIBLING subtrees (since the
#   FSx-isolation refactor). Those two subtree paths don't exist on a fresh
#   FSx volume yet — so use-env would fail with "no such file or directory"
#   from the NFS server. This script is the one that creates them, ONCE,
#   from a temp mount of the FSx root. After that, use-env's leaf-subtree
#   mounts work cleanly forever.
BOOTSTRAP_MNT="/mnt/fsx-bootstrap"
sudo mkdir -p "\$BOOTSTRAP_MNT"
echo "  Mounting \$FSX_DNS:/fsx -> \$BOOTSTRAP_MNT (temporary)"
sudo mount -t nfs4 -o vers=4.1,port=2049 "\$FSX_DNS:/fsx" "\$BOOTSTRAP_MNT"

echo "=== 4. Create sibling subtrees on FSx ==="
# Two top-level subtrees, mounted independently by downstream consumers:
#   /fsx/www    → /var/www on nginx + PHP + deploy-host fleets
#                 (Drupal source, drupal-private, drupal-config, sites/)
#   /fsx/nginx  → /etc/nginx/shared on nginx + deploy-host fleets
#                 (per-env vhost configs)
# Separation matters: PHP-FPM fleet mounts ONLY /fsx/www, so PHP workers
# CANNOT see /fsx/nginx via filesystem traversal — defense in depth against
# information disclosure of nginx vhost configs through a PHP file-read bug.
# See docs/FSX-LAYOUT.md for the full rationale.
sudo mkdir -p "\$BOOTSTRAP_MNT/www" "\$BOOTSTRAP_MNT/nginx/sites-enabled"
sudo chmod 755 "\$BOOTSTRAP_MNT/www" "\$BOOTSTRAP_MNT/nginx" "\$BOOTSTRAP_MNT/nginx/sites-enabled"

# Multi-tenant site root inside /fsx/www — install-drupal / install-site write here
sudo mkdir -p "\$BOOTSTRAP_MNT/www/sites"
sudo chmod 755 "\$BOOTSTRAP_MNT/www/sites"

echo "  Layout created:"
sudo ls -la "\$BOOTSTRAP_MNT/" | head -10

echo "=== 5. Unmount temporary root mount ==="
sudo umount "\$BOOTSTRAP_MNT"
sudo rmdir "\$BOOTSTRAP_MNT" 2>/dev/null || true

echo "=== 6. Activate env via use-env (now uses the sibling subtree mounts) ==="
sudo use-env "\$ENV"
if ! awk -v mp="/var/www" '\$2==mp {found=1; exit} END{exit !found}' /proc/mounts; then
  echo "ERROR: /var/www not mounted after use-env" >&2
  exit 1
fi

echo "=== 7. Verify ==="
echo "  /var/www tree:"
sudo ls -la /var/www | head -20
echo ""
echo "  /etc/nginx/shared/sites-enabled/:"
sudo ls -la /etc/nginx/shared/sites-enabled/

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
