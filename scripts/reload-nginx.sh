#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# reload-nginx: SSM-exec `nginx -s reload` (graceful, no dropped connections)
# across the nginx ASG for the named environment. Use after publishing a
# new vhost to FSx (which nginx hosts mount at /etc/nginx/shared/) — the
# NFS client sees the new file immediately, but the running nginx process
# only loads its config at startup, so a reload is required.
#
# Usage: scripts/reload-nginx.sh <env>
#
# Why reload (not restart): `nginx -s reload` re-execs workers without
# dropping in-flight connections. Restart would 502 anyone mid-request.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# Enumerate targets via the ASG's own view (InService + Healthy), NOT via
# tag-filtered EC2 describe-instances. The tag-filter approach has bitten
# us during instance refresh: EC2's tag index briefly returns terminated
# instance IDs alongside live ones, and SSM rejects the whole batch with
# `InvalidInstanceId — Instances not in a valid state for account`. The
# ASG's Instances[] list is authoritative for "what's actually serving
# traffic right now" and updates as instances are added/removed.
IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ENV}-nginx-asg" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`].InstanceId' \
  --output text 2>/dev/null || true)

if [ -z "$IDS" ]; then
  echo "WARN: no InService+Healthy nginx instances in env=$ENV (ASG ${ENV}-nginx-asg)"
  echo "      The ASG may be mid-refresh or scaled to 0. Try again in a few minutes,"
  echo "      or check: aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ENV}-nginx-asg"
  exit 0
fi

echo "Targeting:"
for I in $IDS; do echo "  $I"; done

CMD_ID=$(aws ssm send-command \
  --instance-ids $IDS \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo nginx -t","sudo nginx -s reload","sleep 1","systemctl is-active nginx"]' \
  --query 'Command.CommandId' --output text)
echo ""
echo "CommandId: $CMD_ID"

echo -n "Waiting for completion"
for _ in $(seq 1 20); do
  PENDING=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "length(CommandInvocations[?Status=='Pending' || Status=='InProgress'])" \
    --output text 2>/dev/null || echo "?")
  if [ "$PENDING" = "0" ]; then
    echo " done."
    break
  fi
  echo -n "."
  sleep 3
done

echo ""
aws ssm list-command-invocations --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[*].[InstanceId,Status]' --output table

FAILED=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
  --query "length(CommandInvocations[?Status!='Success'])" \
  --output text 2>/dev/null || echo "?")
if [ "$FAILED" != "0" ]; then
  echo "WARN: $FAILED instance(s) did not return Success — investigate above."
  echo "Common cause: nginx -t found a syntax error in a vhost config (check /var/log/nginx/error.log on the failing instance)."
  exit 1
fi
echo "✓ nginx reloaded on all targeted instances."
