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
#   1. Wait for /etc/worxco/deploy-host-marker (bootstrap.sh finish marker
#      written by cf-deploy-host's UserData on first boot)
#   2. Pull the latest committed code (in case the deploy-host was created
#      with an older commit than the script we're running here)
#   3. refresh-env-config <env>   (re-resolve FSx DNS, RDS endpoint, etc.)
#   4. use-env <env>              (mount the env's FSx at /var/www)
#   5. make install-drupal ENV=<env>
#
# Why a remote dispatch: install-drupal.sh asserts `/etc/worxco/deploy-host-marker`
# exists. The script can ONLY run on the deploy-host (it needs FSx mounted
# and the deploy-host's tooling). This wrapper sends the work there and
# streams output back.
#
# Why we wait for the marker instead of self-healing: bootstrap.sh is a
# 15-30 min apt-update + composer install + extension install. Running it
# inside our SSM dispatch couples two unrelated lifecycles and blows
# through SSM's executionTimeout. Bootstrap is the responsibility of
# cf-deploy-host's UserData (one-time, at instance boot). This wrapper
# just waits for the marker that UserData writes when done.
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

echo "=== 1. Wait for deploy-host bootstrap to complete ==="
# cf-deploy-host's UserData runs scripts/deploy-host/bootstrap.sh on first
# boot. It writes /etc/worxco/deploy-host-marker when done. We wait up to
# 25 min (apt + composer + extensions can be slow on the t-class instance).
for i in \$(seq 1 50); do
  if [ -f /etc/worxco/deploy-host-marker ] && command -v use-env >/dev/null 2>&1; then
    echo "  bootstrap complete (marker present, use-env in PATH)"
    break
  fi
  echo "  still bootstrapping... (\$(date '+%H:%M:%S'), attempt \$i/50)"
  sleep 30
done
if [ ! -f /etc/worxco/deploy-host-marker ]; then
  echo "ERROR: /etc/worxco/deploy-host-marker not found after 25 min." >&2
  echo "       Check /var/log/cloud-init-output.log or rerun bootstrap manually." >&2
  exit 1
fi

echo "=== 2. Sync to latest committed code ==="
cd "\$REPO_DIR"
# safe.directory: SSM commands run as root; repo is owned by ubuntu. Add a
# system-level allowlist so git tooling invoked from either user works.
git config --system --add safe.directory "\$REPO_DIR" 2>/dev/null || true
sudo -u ubuntu git fetch origin
sudo -u ubuntu git reset --hard origin/main
echo "  HEAD: \$(sudo -u ubuntu git log -1 --format='%h %s')"

echo "=== 3. Refresh env config (resolve FSx DNS, RDS endpoint from SSM) ==="
sudo refresh-env-config "\$ENV"

echo "=== 4. Mount env's FSx at /var/www ==="
sudo use-env "\$ENV"

echo "=== 5. make install-drupal ENV=\$ENV ==="
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

# executionTimeout: use SSM's default 3600s (1 hour). Explicitly setting a
# lower value previously bit us — bootstrap+install can exceed 30 min on a
# cold deploy-host.
CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/install-drupal-remote.sh && bash /tmp/install-drupal-remote.sh\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

# Local poll: up to 45 min wall clock (90 * 30s). Long enough to cover the
# 25-min bootstrap wait + 5-10 min install. If we hit the cap, the SSM
# command is still running — we don't claim failure, we tell the operator
# how to check.
echo "Polling SSM command status (every 30s, up to ~45 min)..."
FINAL_STATUS=""
for i in $(seq 1 90); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress)
      [ $((i % 4)) -eq 0 ] && echo "  [$(date '+%H:%M:%S')] still $STATUS (attempt $i/90)"
      sleep 30
      ;;
    *)
      FINAL_STATUS="$STATUS"
      echo "  [$(date '+%H:%M:%S')] terminal status: $STATUS"
      break
      ;;
  esac
done

echo ""
echo "--- Deploy-host output ---"
aws ssm list-command-invocations --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text

if [ -z "$FINAL_STATUS" ]; then
  echo ""
  echo "WARN: 45-min local poll exhausted but SSM command is still InProgress." >&2
  echo "      Not claiming failure. Check with:" >&2
  echo "      aws ssm list-command-invocations --command-id $CMD_ID --details" >&2
  exit 2
fi
if [ "$FINAL_STATUS" != "Success" ]; then
  echo ""
  echo "ERROR: deploy-host command finished with status: $FINAL_STATUS" >&2
  exit 1
fi
echo ""
echo "✓ install-drupal-remote: Drupal installed (or already-present) for env=$ENV"

# Reload nginx on every nginx instance so the new Drupal vhost (written
# by install-drupal.sh to /var/www/nginx/sites-enabled/drupal.conf) gets
# picked up. nginx hosts see the file immediately via NFS mount, but the
# running nginx process only re-reads its config on reload/restart.
echo ""
echo "--- Reloading nginx fleet to pick up new vhost ---"
"$(dirname "$0")/reload-nginx.sh" "$ENV"
