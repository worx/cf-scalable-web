#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# wait-deploy-host-ready: block until the deploy-host EC2 instance has
# actually finished its bootstrap, not just "the CloudFormation API call
# returned successfully."
#
# Why this exists: `make deploy-deploy-host` finishes when CFN reports
# CREATE_COMPLETE, which only means the AWS resource was provisioned —
# the EC2 instance's UserData (which runs scripts/deploy-host/bootstrap.sh)
# is still doing apt installs, composer install, etc., for another
# 10-15 minutes. Advertising "ready" at CFN-complete is misleading and
# causes downstream commands (init-fsx-layout, deploy-allX) to fail
# because deploy-host isn't actually ready to take SSM dispatches yet.
#
# Two-stage wait:
#   1. SSM agent comes online for the instance (~2-3 min)
#   2. cloud-init reaches a terminal state via `cloud-init status --wait`
#      (covers full UserData completion, ~10-15 min on fresh boot)
#   3. Sanity-check /etc/worxco/deploy-host-marker exists (the marker
#      bootstrap.sh writes near its end)
#
# Usage: scripts/wait-deploy-host-ready.sh

set -euo pipefail

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: cf-deploy-host EC2 instance not running" >&2
  exit 1
fi
echo "Deploy-host: $INSTANCE_ID"

# ============================================================
# Stage 1: SSM agent registration (~2-3 min after instance launch)
# ============================================================
echo "Stage 1/3: Waiting for SSM agent to register..."
for i in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null \
    || echo "")
  if [ "$STATUS" = "Online" ]; then
    echo "  ✓ SSM agent online (after $(( (i-1) * 10 ))s)"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "ERROR: SSM agent did not come online within 5 min" >&2
    exit 1
  fi
  printf "."
  sleep 10
done

# ============================================================
# Stage 2: cloud-init finishes (covers full UserData run)
# ============================================================
echo "Stage 2/3: Waiting for cloud-init (UserData / bootstrap.sh, up to ~25 min)..."
# Send `cloud-init status --wait`, which blocks on the instance until
# cloud-init reaches a terminal state (done / error / disabled). SSM's
# default executionTimeout is 3600s (1h), plenty of headroom.
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cloud-init status --wait || true","echo --- final status ---","cloud-init status --long"]' \
  --query 'Command.CommandId' --output text)
echo "  CommandId: $CMD_ID (polling every 30s)"

START_TS=$(date +%s)
for i in $(seq 1 60); do  # up to 30 min wall clock
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress)
      ELAPSED=$(( $(date +%s) - START_TS ))
      printf "  [%dm%02ds] cloud-init still running...\n" $((ELAPSED/60)) $((ELAPSED%60))
      sleep 30
      ;;
    Success)
      ELAPSED=$(( $(date +%s) - START_TS ))
      printf "  ✓ cloud-init done (after %dm%02ds)\n" $((ELAPSED/60)) $((ELAPSED%60))
      OUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text)
      echo "$OUT" | tail -10
      break
      ;;
    *)
      echo "ERROR: SSM command finished with status: $STATUS" >&2
      aws ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text >&2
      exit 1
      ;;
  esac
  if [ $i -eq 60 ]; then
    echo "ERROR: 30-min wait exceeded; SSM command still InProgress." >&2
    echo "       Check with: aws ssm get-command-invocation --command-id $CMD_ID --instance-id $INSTANCE_ID" >&2
    exit 1
  fi
done

# ============================================================
# Stage 3: Bootstrap marker sanity check
# ============================================================
echo "Stage 3/3: Verifying /etc/worxco/deploy-host-marker exists..."
MARKER_CMD=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["test -f /etc/worxco/deploy-host-marker && echo MARKER_OK || echo MARKER_MISSING"]' \
  --query 'Command.CommandId' --output text)
sleep 3
for i in $(seq 1 10); do
  S=$(aws ssm list-command-invocations --command-id "$MARKER_CMD" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo P)
  [ "$S" != "Pending" ] && [ "$S" != "InProgress" ] && break
  sleep 2
done
MARKER_OUT=$(aws ssm get-command-invocation --command-id "$MARKER_CMD" \
  --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text)
if echo "$MARKER_OUT" | grep -q "MARKER_OK"; then
  echo "  ✓ Bootstrap marker present"
else
  echo "ERROR: cloud-init finished but /etc/worxco/deploy-host-marker is missing." >&2
  echo "       bootstrap.sh likely failed partway. Check /var/log/cloud-init-output.log on the instance." >&2
  exit 1
fi

echo ""
echo "✓ Deploy host is FULLY READY (SSM online, cloud-init done, marker present)"
