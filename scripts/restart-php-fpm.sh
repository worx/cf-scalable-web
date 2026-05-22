#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# restart-php-fpm: SSM-exec `systemctl restart php<ver>-fpm` across both
# PHP ASGs (php74 + php83) for the named environment. Use after editing
# settings.php on FSx or otherwise needing every worker to re-read state
# (OPcache bust, env-var refresh after rotating a secret, etc.).
#
# Usage: scripts/restart-php-fpm.sh <env>
#
# Returns the SSM command's per-instance result table.

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
# ASG's Instances[] list is authoritative; describe-auto-scaling-groups
# accepts multiple group names in one call, so we still get both ASGs in
# a single AWS API call.
IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ENV}-php74-asg" "${ENV}-php83-asg" \
  --query 'AutoScalingGroups[].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`].InstanceId' \
  --output text 2>/dev/null || true)

if [ -z "$IDS" ]; then
  echo "WARN: no InService+Healthy PHP instances in env=$ENV (ASGs ${ENV}-php74-asg + ${ENV}-php83-asg)"
  echo "      The ASGs may be mid-refresh or scaled to 0. Try again in a few minutes,"
  echo "      or check: aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ENV}-php74-asg ${ENV}-php83-asg"
  exit 0
fi

# Pretty-print the target list (one ID per line)
echo "Targeting:"
for I in $IDS; do echo "  $I"; done

CMD_ID=$(aws ssm send-command \
  --instance-ids $IDS \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["PHP_VER=$(cat /opt/worxco/php-version)","sudo systemctl restart php${PHP_VER}-fpm","sleep 1","systemctl is-active php${PHP_VER}-fpm"]' \
  --query 'Command.CommandId' --output text)
echo ""
echo "CommandId: $CMD_ID"

# Wait up to ~60s for the command to complete on all targets
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

# Exit non-zero if any instance failed
FAILED=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
  --query "length(CommandInvocations[?Status!='Success'])" \
  --output text 2>/dev/null || echo "?")
if [ "$FAILED" != "0" ]; then
  echo "WARN: $FAILED instance(s) did not return Success — investigate above."
  exit 1
fi
echo "✓ php-fpm restarted on all targeted instances."
