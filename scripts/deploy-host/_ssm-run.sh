#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/deploy-host/_ssm-run.sh
#
# Purpose:  Internal orchestrator for the `make backup-deploy-host` and
#           `make restore-deploy-host` targets. Uploads the specified
#           deploy-host script + _common.sh to the sandbox deploy-host
#           backups bucket, then uses `aws ssm send-command` to have
#           the deploy-host download and execute it. Polls for
#           completion and displays stdout/stderr.
#
#           Mirrors migration/scripts/_ssm-run-jumpbox.sh but points
#           at the deploy-host stack and the deploy-host backups
#           bucket (both in sandbox account - no cross-account
#           complexity, no Secrets Manager fetch).
#
# Usage:    _ssm-run.sh <script-name>
#           where <script-name> matches scripts/deploy-host/<script-name>.sh
#
# Runs as:  operator on Mac or deploy-host
# Host:     Mac or deploy-host (needs ZI-Sandbox profile)
#
# Environment variables:
#   AWS_REGION                    Region for CFN/SSM/S3 ops (us-east-1)
#   DEPLOY_HOST_STACK             Deploy-host CFN stack (cf-deploy-host)
#   DEPLOY_HOST_BACKUPS_STACK     Backups bucket CFN stack (cf-deploy-host-backups)
#   CONFIRMED                     yes = skip remote script's confirm prompt
#   DRY_RUN                       yes = tell remote script to dry-run
#   POLL_INTERVAL                 Seconds between status polls (default: 15)
#   POLL_TIMEOUT                  Seconds before giving up polling (default: 3600)
#
# Created:  2026-07-15
# ============================================================

set -euo pipefail

# Source shared helpers - use the migration _common.sh (single source
# of truth for the log_* helpers, colors, etc.). Falls back cleanly
# if not present.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/_common.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/_common.sh"
elif [ -f "$SCRIPT_DIR/../../migration/scripts/_common.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../../migration/scripts/_common.sh"
else
  echo "ERROR: cannot find _common.sh" >&2
  exit 1
fi

# ============================================================
# Argument parsing
# ============================================================
if [ $# -ne 1 ]; then
  log_error "Usage: $0 <script-name>"
  log_error "  Example: $0 backup-state"
  exit 2
fi
SCRIPT_NAME="$1"
LOCAL_SCRIPT="scripts/deploy-host/${SCRIPT_NAME}.sh"

if [ ! -f "$LOCAL_SCRIPT" ]; then
  log_error "Local script not found: $LOCAL_SCRIPT"
  log_error "  cwd: $(pwd)"
  log_error "  Are you running from the project root?"
  exit 2
fi

# ============================================================
# Defaults for env vars
# ============================================================
AWS_REGION="${AWS_REGION:-us-east-1}"
DEPLOY_HOST_STACK="${DEPLOY_HOST_STACK:-cf-deploy-host}"
DEPLOY_HOST_BACKUPS_STACK="${DEPLOY_HOST_BACKUPS_STACK:-cf-deploy-host-backups}"
CONFIRMED="${CONFIRMED:-}"
DRY_RUN="${DRY_RUN:-}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

log_step "_ssm-run (deploy-host) - orchestrating '$SCRIPT_NAME'"
log_info "AWS_REGION                  = $AWS_REGION"
log_info "DEPLOY_HOST_STACK           = $DEPLOY_HOST_STACK"
log_info "DEPLOY_HOST_BACKUPS_STACK   = $DEPLOY_HOST_BACKUPS_STACK"
log_info "CONFIRMED                   = ${CONFIRMED:-<unset>}"
log_info "DRY_RUN                     = ${DRY_RUN:-<unset>}"

# ============================================================
# Step 1: Look up deploy-host backups bucket name
# ============================================================
log_step "Step 1: Look up deploy-host backups bucket"

BUCKET_NAME=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "$DEPLOY_HOST_BACKUPS_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='DeployHostBackupsBucketName'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  log_error "Backups bucket stack '$DEPLOY_HOST_BACKUPS_STACK' not deployed."
  log_error "  Deploy first: make deploy-deploy-host-backups"
  exit 1
fi
log_ok "Bucket: $BUCKET_NAME"

# ============================================================
# Step 2: Look up deploy-host instance ID
# ============================================================
log_step "Step 2: Look up deploy-host instance ID"

# Deploy-host CFN doesn't reliably output InstanceId (it may or may not
# depending on template state). Use ec2 describe-instances via the Name
# tag - same pattern as make verify-deploy-host uses.
INSTANCE_ID=$(aws --profile ZI-Sandbox ec2 describe-instances \
    --filters "Name=tag:Name,Values=$DEPLOY_HOST_STACK" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  log_error "Deploy-host instance not found (looked for tag Name=$DEPLOY_HOST_STACK, state=running)."
  log_error "  Deploy first: make deploy-deploy-host"
  exit 1
fi
log_ok "Deploy-host: $INSTANCE_ID"

# ============================================================
# Step 3: Upload scripts to S3
# ============================================================
log_step "Step 3: Upload scripts to s3://$BUCKET_NAME/scripts/"

# We ship the migration _common.sh as the shared helper (single source
# of truth). Deploy-host scripts source it from either their sibling
# _common.sh or from the migration folder path. On the target host we
# put it right next to the script that runs, so relative sourcing works.
if [ ! -f "migration/scripts/_common.sh" ]; then
  log_error "migration/scripts/_common.sh not found (cwd: $(pwd))"
  log_error "  Are you running from the project root?"
  exit 1
fi

aws --profile ZI-Sandbox s3 cp migration/scripts/_common.sh \
    "s3://$BUCKET_NAME/scripts/_common.sh" \
    --region "$AWS_REGION" --quiet
log_ok "Uploaded _common.sh"

aws --profile ZI-Sandbox s3 cp "$LOCAL_SCRIPT" \
    "s3://$BUCKET_NAME/scripts/deploy-host/${SCRIPT_NAME}.sh" \
    --region "$AWS_REGION" --quiet
log_ok "Uploaded ${SCRIPT_NAME}.sh"

# ============================================================
# Step 4: Build SSM send-command parameters JSON
# ============================================================
log_step "Step 4: Build SSM command parameters"

PARAMS_FILE=$(mktemp)
trap 'rm -f "$PARAMS_FILE"' EXIT

# jq builds the JSON so we never have to shell-escape special chars.
# NOTE: `set -eu` (not `-o pipefail`) because SSM's AWS-RunShellScript
# runs /bin/sh (dash on Ubuntu), which doesn't support pipefail. The
# actual downloaded bash script has `#!/bin/bash` and its own
# `set -euo pipefail`.
#
# Preserving relative structure so the downloaded script can source
# _common.sh as a sibling:
#   /opt/deploy-host/scripts/_common.sh
#   /opt/deploy-host/scripts/deploy-host/backup-state.sh
jq -n \
    --arg bucket "$BUCKET_NAME" \
    --arg script "$SCRIPT_NAME" \
    --arg confirmed "$CONFIRMED" \
    --arg dryrun "$DRY_RUN" \
    '{
      commands: [
        "set -eu",
        "mkdir -p /opt/deploy-host/scripts/deploy-host",
        ("aws s3 cp \"s3://" + $bucket + "/scripts/_common.sh\" /opt/deploy-host/scripts/_common.sh --quiet"),
        ("aws s3 cp \"s3://" + $bucket + "/scripts/deploy-host/" + $script + ".sh\" /opt/deploy-host/scripts/deploy-host/" + $script + ".sh --quiet"),
        ("chmod +x /opt/deploy-host/scripts/deploy-host/" + $script + ".sh"),
        ("env CONFIRMED=" + $confirmed + " DRY_RUN=" + $dryrun + " DEPLOY_HOST_BACKUPS_BUCKET=" + $bucket + " /opt/deploy-host/scripts/deploy-host/" + $script + ".sh")
      ]
    }' > "$PARAMS_FILE"

log_ok "Parameters built ($(wc -c < "$PARAMS_FILE") bytes)"

# ============================================================
# Step 5: Dispatch via SSM send-command
# ============================================================
log_step "Step 5: Dispatch to deploy-host via SSM send-command"

CMD_ID=$(aws --profile ZI-Sandbox ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://$PARAMS_FILE" \
    --timeout-seconds "$POLL_TIMEOUT" \
    --comment "make ${SCRIPT_NAME} (deploy-host)" \
    --query 'Command.CommandId' --output text \
    --region "$AWS_REGION")

if [ -z "$CMD_ID" ] || [ "$CMD_ID" = "None" ]; then
  log_error "Failed to dispatch SSM command"
  exit 1
fi

log_ok "CommandId: $CMD_ID"

# ============================================================
# Step 6: Poll for completion
# ============================================================
log_step "Step 6: Poll for completion (every ${POLL_INTERVAL}s, timeout ${POLL_TIMEOUT}s)"
log_info "(Ctrl-C to detach - command continues on deploy-host)"

start_time=$SECONDS
STATUS="Unknown"
while true; do
  elapsed=$(( SECONDS - start_time ))
  if [ "$elapsed" -gt "$POLL_TIMEOUT" ]; then
    echo
    log_error "Poll timeout (${POLL_TIMEOUT}s) exceeded."
    log_error "Command may still be running. Check with:"
    log_error "  aws --profile ZI-Sandbox ssm get-command-invocation \\"
    log_error "      --command-id $CMD_ID --instance-id $INSTANCE_ID --region $AWS_REGION"
    exit 1
  fi

  STATUS=$(aws --profile ZI-Sandbox ssm get-command-invocation \
      --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
      --query Status --output text --region "$AWS_REGION" 2>/dev/null || echo "Pending")

  case "$STATUS" in
    InProgress|Pending|Delayed)
      printf "."
      sleep "$POLL_INTERVAL"
      ;;
    Success)
      echo
      log_ok "Status: Success (elapsed: ${elapsed}s)"
      break
      ;;
    Failed|Cancelled|TimedOut|Cancelling)
      echo
      log_error "Status: $STATUS (elapsed: ${elapsed}s)"
      break
      ;;
    *)
      echo
      log_warn "Unexpected status: '$STATUS'"
      break
      ;;
  esac
done

# ============================================================
# Step 7: Fetch and display stdout/stderr
# ============================================================
log_step "Step 7: Remote script output"

printf '\n%b--- stdout ---%b\n' "$BLUE" "$NC"
aws --profile ZI-Sandbox ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text --region "$AWS_REGION" \
    2>/dev/null || echo "(no stdout captured)"

printf '\n%b--- stderr ---%b\n' "$BLUE" "$NC"
aws --profile ZI-Sandbox ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query StandardErrorContent --output text --region "$AWS_REGION" \
    2>/dev/null || echo "(no stderr captured)"

# ============================================================
# Done
# ============================================================
echo
log_step "$SCRIPT_NAME orchestration complete"

if [ "$STATUS" = "Success" ]; then
  log_ok "Remote script uploaded its log to:"
  log_info "  s3://$BUCKET_NAME/logs/$(date -u +%Y-%m-%d)/${SCRIPT_NAME}-deploy-host-*.log"
else
  log_error "Exit code non-zero due to Status: $STATUS"
  exit 1
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
