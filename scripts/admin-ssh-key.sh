#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# admin-ssh-key: manage the admin SSH public-key registry used by the
# deploy-host's authorized_keys.
#
# Storage: SSM Parameter Store under /worxco/admin/ssh-public-keys/<owner>.
#   - One param per owner. Owner name is freeform (e.g., "kurt",
#     "alice", "kurt-laptop", "ci-runner").
#   - Value is the full single-line SSH public key (e.g., "ssh-ed25519 AAAA... user@host").
#
# Subcommands:
#   add NAME FILE      add or replace an admin key; auto-sync after
#   remove NAME        delete an admin key; auto-sync after
#   list               show all configured admin keys (name + fingerprint)
#   sync               push current SSM registry to the running deploy-host
#
# Why SSH keys + SSM Session Manager (not port 22): the public key in
# authorized_keys lets sshd authenticate the inbound connection — but
# the inbound connection is tunneled through SSM Session Manager via
# the AWS-StartSSHSession document, NOT via port 22 on the security
# group. Port 22 stays closed everywhere. See
# docs/memory/admin-access-policy.md for the full design.

set -euo pipefail

usage() {
  cat <<EOF >&2
Usage: $0 <subcommand> [args]

Subcommands:
  add <name> <pubkey-file>    Add/replace an admin SSH key (auto-syncs to deploy-host)
  remove <name>               Remove an admin SSH key (auto-syncs to deploy-host)
  list                        List configured admin keys (name + fingerprint)
  sync                        Push current SSM registry to the running deploy-host

Examples:
  $0 add kurt ~/.ssh/id_ed25519.pub
  $0 list
  $0 remove alice
  $0 sync
EOF
  exit 2
}

SSM_PATH="/worxco/admin/ssh-public-keys"

# Resolve deploy-host instance ID (lazy — only when sync is needed)
deploy_host_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=cf-deploy-host" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null
}

dispatch_sync() {
  local DEPLOY_ID
  DEPLOY_ID=$(deploy_host_id)
  if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
    echo "WARN: deploy-host not running — SSM registry updated, but no live host to sync." >&2
    return 0
  fi
  echo "Syncing to deploy-host $DEPLOY_ID..."
  # Use the script from the repo (already on the deploy-host via bootstrap clone).
  # Falls back to inlining the script body if the file doesn't exist yet
  # (e.g., deploy-host hasn't pulled the latest commit).
  local CMD_ID
  CMD_ID=$(aws ssm send-command \
    --instance-ids "$DEPLOY_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cd /home/ubuntu/projects/cf-scalable-web && sudo -u ubuntu git fetch origin && sudo -u ubuntu git reset --hard origin/main && sudo bash scripts/deploy-host/sync-admin-ssh-keys.sh"]' \
    --query 'Command.CommandId' --output text)
  echo "CommandId: $CMD_ID"
  for _ in $(seq 1 30); do
    STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
      --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)
    [ "$STATUS" != "Pending" ] && [ "$STATUS" != "InProgress" ] && break
    sleep 2
  done
  echo ""
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
    --query 'StandardOutputContent' --output text | tail -10
  if [ "$STATUS" != "Success" ]; then
    echo "ERROR: sync failed ($STATUS)" >&2
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
      --query 'StandardErrorContent' --output text >&2
    return 1
  fi
}

CMD="${1:-}"
shift || true

case "$CMD" in
  add)
    NAME="${1:-}"; FILE="${2:-}"
    [ -z "$NAME" ] && usage
    [ -z "$FILE" ] && usage
    [ ! -f "$FILE" ] && { echo "ERROR: no such file: $FILE" >&2; exit 1; }
    KEY=$(head -1 "$FILE" | tr -d '\r\n')
    case "$KEY" in
      ssh-dss*)
        echo "ERROR: DSA keys (ssh-dss) are deprecated and rejected by modern OpenSSH." >&2
        echo "       Generate a modern key:" >&2
        echo "         ssh-keygen -t ed25519 -f ~/.ssh/my-new-key -C 'user@host'" >&2
        echo "       Then: make admin-ssh-key-add NAME=$NAME FILE=~/.ssh/my-new-key.pub" >&2
        exit 1
        ;;
      ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*|sk-ssh-ed25519*|sk-ecdsa-sha2-*) ;;
      *) echo "ERROR: $FILE doesn't look like a supported SSH public key type" >&2; exit 1 ;;
    esac
    aws ssm put-parameter \
      --name "$SSM_PATH/$NAME" \
      --value "$KEY" \
      --type String \
      --overwrite \
      --description "Admin SSH public key for $NAME (managed by admin-ssh-key.sh)" > /dev/null
    echo "✓ Added admin key for $NAME"
    dispatch_sync
    ;;

  remove)
    NAME="${1:-}"
    [ -z "$NAME" ] && usage
    if aws ssm delete-parameter --name "$SSM_PATH/$NAME" 2>/dev/null; then
      echo "✓ Removed admin key for $NAME"
      dispatch_sync
    else
      echo "Not found: $NAME (no such SSM param)"
      exit 1
    fi
    ;;

  list)
    PARAMS_JSON=$(aws ssm get-parameters-by-path \
      --path "$SSM_PATH/" \
      --query 'Parameters[*]' --output json 2>/dev/null || echo "[]")
    COUNT=$(echo "$PARAMS_JSON" | jq 'length')
    if [ "$COUNT" = "0" ]; then
      echo "(no admin keys configured)"
    else
      printf "%-20s  %-15s  %s\n" "OWNER" "TYPE" "FINGERPRINT"
      # Tolerate any per-row failures (e.g., ssh-keygen refusing to
      # fingerprint a key type it considers deprecated). pipefail+set -e
      # would otherwise kill the whole listing for one bad row.
      echo "$PARAMS_JSON" | jq -r '.[] | "\(.Name)\t\(.Value)"' | while IFS=$'\t' read -r N V; do
        OWNER=$(basename "$N")
        TYPE=$(echo "$V" | awk '{print $1}')
        FP=$(echo "$V" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || FP="(unfingerprintable)"
        [ -z "$FP" ] && FP="(unfingerprintable)"
        printf "%-20s  %-15s  %s\n" "$OWNER" "$TYPE" "$FP"
      done || true
    fi
    ;;

  sync)
    dispatch_sync
    ;;

  *)
    usage
    ;;
esac
