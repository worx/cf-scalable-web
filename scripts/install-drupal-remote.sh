#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# install-drupal-remote: orchestrate `make install-drupal ENV=<env>` on the
# deploy-host via SSM. Used by `make deploy-allX` to take a freshly-deployed
# infrastructure all the way to a working Drupal in one command.
#
# What this does on the deploy-host (via a single SSM dispatch):
#   1. Pull the latest committed code (so the deploy-host runs the same
#      bootstrap/install scripts that match the templates just deployed)
#   2. Self-heal: if `use-env` doesn't exist yet (pre-cutover deploy-host),
#      re-run bootstrap.sh to install it
#   3. Clean up any stale pre-cutover FSx mount at /var/www/<env>
#   4. refresh-env-config <env>   (re-resolve FSx DNS, RDS endpoint, etc.)
#   5. use-env <env>              (mount the env's FSx at /var/www)
#   6. make install-drupal ENV=<env>
#
# Why a remote dispatch: install-drupal.sh asserts `/etc/worxco/deploy-host-marker`
# exists. The script can ONLY run on the deploy-host (it needs FSx mounted
# and the deploy-host's tooling). This wrapper sends the work there and
# streams output back.
#
# Usage: scripts/install-drupal-remote.sh <env>

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
echo "Installing Drupal for env=$ENV via SSM..."

# Build the inner script. Sent as base64 to dodge SSM JSON-escaping hell.
INNER_SCRIPT=$(cat <<EOF_INNER
#!/bin/bash
set -euo pipefail
ENV="$ENV"
REPO_DIR="/home/ubuntu/projects/cf-scalable-web"

cd "\$REPO_DIR"

echo "=== 1. Sync deploy-host to latest committed code ==="
sudo -u ubuntu git fetch origin
sudo -u ubuntu git reset --hard origin/main
echo "  HEAD: \$(git log -1 --format='%h %s')"

echo "=== 2. Self-heal: install use-env if missing (pre-cutover host) ==="
if ! command -v use-env >/dev/null 2>&1; then
  echo "  use-env not found — re-running bootstrap.sh"
  sudo bash scripts/deploy-host/bootstrap.sh
else
  echo "  use-env present — skipping bootstrap"
fi

echo "=== 3. Clear any stale pre-cutover mount at /var/www/\$ENV ==="
if mountpoint -q "/var/www/\$ENV" 2>/dev/null; then
  echo "  unmounting stale /var/www/\$ENV"
  sudo umount -lf "/var/www/\$ENV" || true
fi
# Strip pre-cutover fstab entry if present
if grep -q "/var/www/\$ENV " /etc/fstab 2>/dev/null; then
  echo "  removing pre-cutover fstab entry for /var/www/\$ENV"
  sudo sed -i "\\|/var/www/\$ENV |d" /etc/fstab
fi

echo "=== 4. Refresh env config (FSx DNS may have changed) ==="
sudo refresh-env-config "\$ENV"

echo "=== 5. Mount env's FSx at /var/www ==="
sudo use-env "\$ENV"

echo "=== 6. make install-drupal ENV=\$ENV ==="
cd "\$REPO_DIR"
if [ -f "/var/www/drupal/.installed" ]; then
  echo "  Drupal already installed on this FSx — skipping install (idempotent)."
  echo "  To force reinstall: make reinstall-drupal ENV=\$ENV"
else
  make install-drupal ENV="\$ENV"
fi

echo "=== Done ==="
EOF_INNER
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/install-drupal-remote.sh && bash /tmp/install-drupal-remote.sh\"],\"executionTimeout\":[\"1800\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

echo -n "Waiting for install (up to ~10 min)"
# Poll every 10s, up to ~10 min. Install typically takes 3-5 min.
for _ in $(seq 1 60); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "."; sleep 10 ;;
    *) echo " $STATUS."; break ;;
  esac
done

echo ""
echo "--- Deploy-host output ---"
aws ssm list-command-invocations --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text

STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
  --query "CommandInvocations[0].Status" --output text 2>/dev/null)
if [ "$STATUS" != "Success" ]; then
  echo ""
  echo "ERROR: deploy-host command finished with status: $STATUS" >&2
  exit 1
fi
echo ""
echo "✓ install-drupal-remote: Drupal installed (or already-present) for env=$ENV"
