#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/dispatch-clean-migration-baks.sh
#
# Purpose: Universal entry point for `make clean-migration-baks`.
# Routes to the right implementation based on where it's invoked:
#
#   Mac (Darwin)             → SSM to deploy-host, run the worker there
#   Deploy-host, running root → run the worker directly (no sudo)
#   Deploy-host, non-root     → sudo to run the worker
#   Anywhere else            → error out — we don't know how to reach FSx
#
# The point: the operator runs `make clean-migration-baks` (dry-run) or
# `make clean-migration-baks CONFIRMED=yes` (delete) from wherever they
# happen to be, and this script figures out the plumbing.
#
# Also passes CONFIRMED through as an env var to the worker.

set -euo pipefail

CONFIRMED="${CONFIRMED:-}"
# Repo root derived from this script's own location so the dispatcher
# works regardless of the caller's cwd. `make clean-migration-baks`
# can be invoked from repo root or from migration/ (whose Makefile
# owns the target); both call this dispatcher.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_ABS_LOCAL="$REPO_ROOT/migration/scripts/deploy-host/clean-migration-baks.sh"

# ---------------------------------------------------------------------
# Detect the environment we're running in
# ---------------------------------------------------------------------
UNAME=$(uname)

# Deploy-host marker: this project's bootstrap.sh creates /etc/worxco/
# and /var/www is the FSx mount root. Both together reliably identify
# the deploy-host without relying on hostname pattern matching (which
# would break as ASGs rotate instances).
is_deploy_host() {
  [ -d /etc/worxco ] && [ -d /var/www ] && mount | grep -q "on /var/www type nfs"
}

# ---------------------------------------------------------------------
# Case 1: Mac — dispatch via SSM
# ---------------------------------------------------------------------
if [ "$UNAME" = "Darwin" ]; then
  DEPLOY_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=cf-deploy-host" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

  if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
    echo "ERROR: deploy-host is not running." >&2
    echo "  Start it: make resume-deploy-host" >&2
    exit 1
  fi
  echo "Deploy-host: $DEPLOY_ID"

  # Inner script — heredoc quoted so nothing expands locally. Bakes in
  # the CONFIRMED value via a separate substitution below.
  INNER_SCRIPT=$(cat <<'INNER_EOF'
#!/bin/bash
set -eu
REPO=/home/ubuntu/projects/cf-scalable-web
cd "$REPO"
echo "=== git pull (best-effort, as ubuntu) ==="
su - ubuntu -c "cd '$REPO' && git pull --quiet" \
  || echo "WARN: git pull failed — using existing checkout"

echo ""
echo "=== running clean-migration-baks.sh (CONFIRMED=__CONFIRMED__) ==="
sudo bash "$REPO/migration/scripts/deploy-host/clean-migration-baks.sh" CONFIRMED=__CONFIRMED__
INNER_EOF
  )
  INNER_SCRIPT="${INNER_SCRIPT//__CONFIRMED__/$CONFIRMED}"
  B64=$(printf '%s' "$INNER_SCRIPT" | base64 | tr -d '\n')

  CMD_ID=$(aws ssm send-command \
    --instance-ids "$DEPLOY_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/clean-migration-baks-runner.sh && bash /tmp/clean-migration-baks-runner.sh\"]}" \
    --query 'Command.CommandId' --output text)
  echo "CommandId: $CMD_ID"
  echo "Polling…"

  for _ in $(seq 1 60); do
    STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
      --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
    case "$STATUS" in
      Pending|InProgress) sleep 2 ;;
      *) break ;;
    esac
  done

  echo ""
  echo "=== Status: $STATUS ==="
  echo ""
  STDOUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
  STDERR=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardErrorContent' --output text 2>/dev/null || echo "")

  [ -n "$STDOUT" ] && echo "$STDOUT"
  if [ -n "$STDERR" ]; then
    echo "--- stderr ---"
    echo "$STDERR"
  fi

  [ "$STATUS" = "Success" ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------
# Case 2/3: Linux deploy-host — run the worker directly
# ---------------------------------------------------------------------
if is_deploy_host; then
  if [ ! -f "$WORKER_ABS_LOCAL" ]; then
    echo "ERROR: worker script not found at $WORKER_ABS_LOCAL" >&2
    echo "  (derived from dispatcher location $SCRIPT_DIR)" >&2
    exit 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    # Already root — no sudo needed.
    exec bash "$WORKER_ABS_LOCAL" CONFIRMED="$CONFIRMED"
  else
    # Not root — need sudo. Pass CONFIRMED via env preservation.
    exec sudo CONFIRMED="$CONFIRMED" bash "$WORKER_ABS_LOCAL"
  fi
fi

# ---------------------------------------------------------------------
# Case 4: Unknown environment
# ---------------------------------------------------------------------
echo "ERROR: This target only runs on macOS (dispatches via SSM) or on" >&2
echo "       the deploy-host (which has /var/www mounted from FSx)." >&2
echo "       Detected uname=$UNAME. If you're on the deploy-host but the" >&2
echo "       detector missed it, check that /var/www is an NFS mount and" >&2
echo "       /etc/worxco exists." >&2
exit 1
