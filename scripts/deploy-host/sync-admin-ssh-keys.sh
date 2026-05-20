#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# sync-admin-ssh-keys: pull /worxco/admin/ssh-public-keys/* from SSM
# Parameter Store and write them to ubuntu's authorized_keys.
#
# Designed to be idempotent. Safe to run repeatedly. Invoked by:
#   - bootstrap.sh (at deploy-host first boot)
#   - SSM dispatch from local Mac via `make admin-ssh-key-sync`
#
# This enables scp/sftp/rsync over an SSM Session Manager proxy (using
# the AWS-StartSSHSession document) WITHOUT opening port 22 on any SG.
# See docs/memory/admin-access-policy.md for the full design.
#
# Usage:  sudo bash scripts/deploy-host/sync-admin-ssh-keys.sh

set -euo pipefail

AUTHORIZED=/home/ubuntu/.ssh/authorized_keys

# Ensure .ssh dir exists with correct permissions
install -d -m 0700 -o ubuntu -g ubuntu /home/ubuntu/.ssh

TMP=$(mktemp)
{
  echo "# /home/ubuntu/.ssh/authorized_keys"
  echo "# Managed by scripts/deploy-host/sync-admin-ssh-keys.sh."
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Source: SSM Parameter Store at /worxco/admin/ssh-public-keys/*"
  echo "#"
  echo "# Edits to this file will be overwritten on next sync. To add or"
  echo "# remove keys, use the make targets on your local machine:"
  echo "#   make admin-ssh-key-add NAME=<owner> FILE=<path-to-pubkey>"
  echo "#   make admin-ssh-key-remove NAME=<owner>"
  echo "#   make admin-ssh-key-list"
  echo "#   make admin-ssh-key-sync"
  echo ""

  PARAMS_JSON=$(aws ssm get-parameters-by-path \
    --path /worxco/admin/ssh-public-keys/ \
    --query 'Parameters[*]' --output json 2>/dev/null || echo "[]")

  COUNT=$(echo "$PARAMS_JSON" | jq 'length')

  if [ "$COUNT" = "0" ]; then
    echo "# (no admin keys currently configured in SSM)"
  else
    # Iterate, name + key per entry
    echo "$PARAMS_JSON" | jq -r '.[] | "\(.Name)\t\(.Value)"' | while IFS=$'\t' read -r NAME VALUE; do
      OWNER=$(basename "$NAME")
      echo "# Owner: $OWNER"
      echo "$VALUE"
      echo ""
    done
  fi
} > "$TMP"

install -m 0600 -o ubuntu -g ubuntu "$TMP" "$AUTHORIZED"
rm -f "$TMP"

KEY_COUNT=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTHORIZED" 2>/dev/null || echo 0)
echo "✓ /home/ubuntu/.ssh/authorized_keys synced from SSM ($KEY_COUNT key(s))"
