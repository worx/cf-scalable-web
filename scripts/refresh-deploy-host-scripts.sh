#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/refresh-deploy-host-scripts.sh
#
# Reinstall the small set of scripts that bootstrap.sh copies from the
# git checkout into /usr/local/sbin/ (and one sudoers file). Faster than
# re-running the full bootstrap when only these helpers have changed.
#
# Files reinstalled (matches bootstrap.sh:519-521):
#   /usr/local/sbin/use-env
#   /usr/local/sbin/refresh-env-config
#   /etc/sudoers.d/worxco-refresh-env-config
#
# Also does a git pull FIRST so the copy reflects the latest committed
# version, not whatever was on the deploy-host's disk at the time of
# invocation.
#
# Why this exists: bootstrap.sh installs these as COPIES, not symlinks
# — so `git pull` on the deploy-host updates the source in the checkout
# but leaves the installed copy stale. Discovered 2026-07-20 when
# operator ran the salt→SSM upgrade path and refresh-env-config didn't
# emit the new DRUPAL_HASH_SALT line because /usr/local/sbin/ still
# had the pre-commit version.
#
# Usage: scripts/refresh-deploy-host-scripts.sh
#
# Dispatched via SSM. Mac operator: `make refresh-deploy-host-scripts`

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

log_init "refresh-deploy-host-scripts"
trap 'log_upload_and_exit ""' EXIT

log_step "refresh-deploy-host-scripts — reinstalling /usr/local/sbin/ copies"

DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  log_error "deploy-host is not running. Start it (make resume-deploy-host) and retry."
  exit 1
fi
log_info "Deploy-host: $DEPLOY_ID"

# Inner script — git-pulls the repo, then reinstalls the three files
# with the same modes bootstrap.sh uses. Git safe.directory inline
# same as scripts/dispatch-db-backup.sh — SSM runs as root, repo is
# ubuntu-owned.
INNER_SCRIPT=$(cat <<'INNER_EOF'
#!/bin/bash
set -eu
REPO=/home/ubuntu/projects/cf-scalable-web
cd "$REPO"
echo "=== git pull (best-effort) ==="
git -c safe.directory="$REPO" pull --quiet \
  || echo "WARN: git pull failed — reinstalling from existing checkout"

echo "=== reinstalling /usr/local/sbin/use-env ==="
install -m 0755 "$REPO/scripts/deploy-host/use-env" /usr/local/sbin/use-env

echo "=== reinstalling /usr/local/sbin/refresh-env-config ==="
install -m 0755 "$REPO/scripts/deploy-host/refresh-env-config" /usr/local/sbin/refresh-env-config

echo "=== reinstalling /etc/sudoers.d/worxco-refresh-env-config ==="
install -m 0440 "$REPO/scripts/deploy-host/worxco-refresh-env-config.sudoers" /etc/sudoers.d/worxco-refresh-env-config

echo "=== Done. Fresh copies installed. ==="
ls -la /usr/local/sbin/use-env /usr/local/sbin/refresh-env-config /etc/sudoers.d/worxco-refresh-env-config
INNER_EOF
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/refresh-deploy-host-scripts.sh && bash /tmp/refresh-deploy-host-scripts.sh\"]}" \
  --query 'Command.CommandId' --output text)
log_info "CommandId: $CMD_ID"

log_info "Polling (should complete in seconds)..."
for _ in $(seq 1 60); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) sleep 2 ;;
    *) break ;;
  esac
done

STDOUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
STDERR=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardErrorContent' --output text 2>/dev/null || echo "")

if [ -n "$STDOUT" ]; then
  echo "$STDOUT"
fi
if [ -n "$STDERR" ]; then
  echo "--- stderr ---"
  echo "$STDERR"
fi

if [ "$STATUS" = "Success" ]; then
  log_ok "Refresh complete."
  exit 0
else
  log_error "Refresh FAILED (SSM status: $STATUS)."
  exit 1
fi
