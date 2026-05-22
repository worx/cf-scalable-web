#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# unmount-deploy-host-fsx: SSM-dispatch `use-env none` to the deploy-host,
# detaching any active FSx mounts AND scrubbing the worxco fstab block
# BEFORE destroy-storage tears down FSx.
#
# Why this exists:
#   destroy-all leaves the deploy-host running by design (it's the operator
#   workbench, not part of the workload). But if destroy-storage tears down
#   FSx while the deploy-host still has kernel NFS mounts attached, those
#   mounts go stale — the kernel keeps trying to talk to a server that
#   doesn't exist. On the deploy-host's next stop+start (or its next
#   use-env invocation), stat() on the mount path hangs in D-state forever,
#   and the next deploy-allX wedges in init-fsx-layout.
#
#   `use-env none` (run BEFORE FSx is destroyed, while the mounts are
#   still healthy) cleanly umounts /var/www and /etc/nginx/shared AND
#   removes the worxco fstab block, so no stale state can survive into
#   the next deploy cycle.
#
# Idempotent: if no deploy-host is running, prints a notice and exits 0.
# Tolerant: warnings instead of hard fails — destroy-all must not halt
# on a deploy-host cleanup issue.
#
# Usage: scripts/unmount-deploy-host-fsx.sh

set -euo pipefail

DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  echo "No running deploy-host — nothing to unmount."
  exit 0
fi

echo "Deploy-host: $DEPLOY_ID"
echo "Unmounting FSx via 'use-env none' (clean detach + fstab cleanup)..."

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo /usr/local/sbin/use-env none 2>&1 || true"]' \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID"

echo -n "Waiting"
STATUS="Pending"
for _ in $(seq 1 24); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "."; sleep 5 ;;
    *) echo " $STATUS"; break ;;
  esac
done

echo ""
echo "--- Deploy-host output ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || true

if [ "$STATUS" != "Success" ]; then
  echo ""
  echo "WARN: use-env none did not return Success (status=$STATUS)" >&2
  echo "      destroy-storage will proceed but stale FSx mounts may carry" >&2
  echo "      over to the next deploy-allX. If init-fsx-layout hangs on" >&2
  echo "      the next run, SSM into the deploy-host and run:" >&2
  echo "        sudo umount -f -l /etc/nginx/shared" >&2
  echo "        sudo umount -f -l /var/www" >&2
  echo "        sudo sed -i '/^# worxco-use-env\$/,/^\$/d' /etc/fstab" >&2
  exit 0  # NOT exit 1 — destroy-all must not halt on this
fi

echo "✓ Deploy-host FSx unmounted; ready for destroy-storage"
