#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/_ssm-run-jumpbox.sh
#
# Purpose:  Internal orchestrator for the `make dump-*` targets.
#           Uploads the specified jumpbox script + _common.sh to the
#           sandbox migration S3 bucket, then uses `aws ssm send-command`
#           to have the jumpbox download and execute it. Polls for
#           completion and displays stdout/stderr.
#
#           The prefix `_` on the filename indicates this is a helper
#           called by Makefile targets, not invoked directly by operators.
#
# Usage:    _ssm-run-jumpbox.sh <script-name>
#           where <script-name> matches scripts/jumpbox/<script-name>.sh
#
# Runs as:  operator on Mac or deploy-host
# Host:     Mac or deploy-host (needs ZI-Sandbox + ZoningInfoAdmin profiles)
#
# Environment variables (the Makefile provides these; operator can override):
#   AWS_REGION       Region for all CFN/SSM/S3 ops       (default: us-east-1)
#   BUCKET_STACK     Migration bucket CFN stack name     (sandbox)
#   JUMPBOX_STACK    Migration jumpbox CFN stack name    (prod)
#   SECRET_NAME      Secrets Manager entry name          (passed to remote script)
#   CONFIRMED        yes = skip remote script's confirm prompt
#   DRY_RUN          yes = tell remote script to dry-run
#   POLL_INTERVAL    Seconds between status polls        (default: 15)
#   POLL_TIMEOUT     Seconds before giving up polling    (default: 3600)
#
# Behavior:
#   - Sources scripts/_common.sh for colors + log_* helpers
#   - Does NOT call log_init (no local log file — the interesting logs
#     land on the jumpbox and get uploaded to s3://.../logs/ by the
#     remote script's trap)
#   - Ctrl-C during polling detaches; the remote command keeps running.
#     Check status later with: aws --profile ZoningInfoAdmin ssm \
#       get-command-invocation --command-id <ID> --instance-id <INSTANCE>
#
# Created:  2026-07-13
# ============================================================

set -euo pipefail

# Source shared color/logging helpers. We use log_info/log_ok/log_error
# for consistent visuals but skip log_init — no local log file needed
# since the real logs are captured on the jumpbox side.
source "$(dirname "$(readlink -f "$0")")/_common.sh"

# ============================================================
# Argument parsing
# ============================================================
if [ $# -ne 1 ]; then
  log_error "Usage: $0 <script-name>"
  log_error "  Example: $0 dump-mysql"
  exit 2
fi
SCRIPT_NAME="$1"
LOCAL_SCRIPT="scripts/jumpbox/${SCRIPT_NAME}.sh"

if [ ! -f "$LOCAL_SCRIPT" ]; then
  log_error "Local script not found: $LOCAL_SCRIPT"
  log_error "  cwd: $(pwd)"
  log_error "  Are you running from the migration/ directory?"
  exit 2
fi

# ============================================================
# Defaults for env vars (Makefile passes real values; direct callers
# get sane defaults matching the deployed stack names)
# ============================================================
AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_STACK="${BUCKET_STACK:-cf-scalable-web-sandbox-migration-bucket}"
JUMPBOX_STACK="${JUMPBOX_STACK:-cf-migration-jumpbox}"
SECRET_NAME="${SECRET_NAME:-cf-migration/prod-mysql-zinew}"
CONFIRMED="${CONFIRMED:-}"
DRY_RUN="${DRY_RUN:-}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

log_step "_ssm-run-jumpbox — orchestrating '$SCRIPT_NAME'"
log_info "AWS_REGION    = $AWS_REGION"
log_info "BUCKET_STACK  = $BUCKET_STACK  (sandbox)"
log_info "JUMPBOX_STACK = $JUMPBOX_STACK  (prod)"
log_info "SECRET_NAME   = $SECRET_NAME"
log_info "CONFIRMED     = ${CONFIRMED:-<unset>}"
log_info "DRY_RUN       = ${DRY_RUN:-<unset>}"

# ============================================================
# Step 1: Look up sandbox migration bucket name
# ============================================================
log_step "Step 1: Look up migration bucket (sandbox)"

BUCKET_NAME=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "$BUCKET_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  log_error "Migration bucket stack '$BUCKET_STACK' not deployed in sandbox account."
  log_error "  Deploy first: cd migration && make deploy-bucket"
  exit 1
fi
log_ok "Bucket: $BUCKET_NAME"

# ============================================================
# Step 2: Look up prod jumpbox instance ID
# ============================================================
log_step "Step 2: Look up jumpbox instance ID (prod)"

INSTANCE_ID=$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
    --stack-name "$JUMPBOX_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='JumpboxInstanceId'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  log_error "Migration jumpbox stack '$JUMPBOX_STACK' not deployed in prod account."
  log_error "  Deploy first: cd migration && make deploy-jumpbox"
  exit 1
fi
log_ok "Jumpbox: $INSTANCE_ID"

# ============================================================
# Step 3: Upload scripts to S3 (sandbox side, ZI-Sandbox profile)
# ============================================================
log_step "Step 3: Upload scripts to s3://$BUCKET_NAME/scripts/"

# Sanity: local _common.sh must be present alongside the caller
if [ ! -f "scripts/_common.sh" ]; then
  log_error "scripts/_common.sh not found (cwd: $(pwd))"
  log_error "  Are you running from the migration/ directory?"
  exit 1
fi

aws --profile ZI-Sandbox s3 cp scripts/_common.sh \
    "s3://$BUCKET_NAME/scripts/_common.sh" \
    --region "$AWS_REGION" --quiet
log_ok "Uploaded _common.sh"

aws --profile ZI-Sandbox s3 cp "$LOCAL_SCRIPT" \
    "s3://$BUCKET_NAME/scripts/jumpbox/${SCRIPT_NAME}.sh" \
    --region "$AWS_REGION" --quiet
log_ok "Uploaded ${SCRIPT_NAME}.sh"

# ============================================================
# Step 4: Build SSM send-command parameters JSON
# ============================================================
log_step "Step 4: Build SSM command parameters"

PARAMS_FILE=$(mktemp)
trap 'rm -f "$PARAMS_FILE"' EXIT

# jq builds the JSON so we never have to shell-escape special chars
# in bucket names, script names, or env values. The commands array is
# a series of shell steps SSM runs in one dash session (AWS-RunShellScript
# document uses /bin/sh, not bash).
#
# NOTE on `set -eu` vs `set -euo pipefail`:
#   SSM's default shell is dash, which doesn't support `-o pipefail`.
#   We use `-eu` here (POSIX-compatible: exit on error + on unset var).
#   The actual downloaded script (`dump-<X>.sh`) has `#!/bin/bash` and
#   its own `set -euo pipefail` — that's where pipefail actually matters
#   because that's where the pipelines live.
#
# Preserving relative structure — dump-mysql.sh sources ../_common.sh,
# so both files must live in matching paths on the jumpbox:
#   /opt/migration/scripts/_common.sh
#   /opt/migration/scripts/jumpbox/dump-mysql.sh
jq -n \
    --arg bucket "$BUCKET_NAME" \
    --arg script "$SCRIPT_NAME" \
    --arg secret "$SECRET_NAME" \
    --arg confirmed "$CONFIRMED" \
    --arg dryrun "$DRY_RUN" \
    '{
      commands: [
        "set -eu",
        "mkdir -p /opt/migration/scripts/jumpbox",
        ("aws s3 cp \"s3://" + $bucket + "/scripts/_common.sh\" /opt/migration/scripts/_common.sh --quiet"),
        ("aws s3 cp \"s3://" + $bucket + "/scripts/jumpbox/" + $script + ".sh\" /opt/migration/scripts/jumpbox/" + $script + ".sh --quiet"),
        ("chmod +x /opt/migration/scripts/jumpbox/" + $script + ".sh"),
        ("env CONFIRMED=" + $confirmed + " DRY_RUN=" + $dryrun + " MIGRATION_BUCKET=" + $bucket + " SECRET_NAME=" + $secret + " /opt/migration/scripts/jumpbox/" + $script + ".sh")
      ]
    }' > "$PARAMS_FILE"

log_ok "Parameters built ($(wc -c < "$PARAMS_FILE") bytes)"

# ============================================================
# Step 5: Dispatch via SSM send-command
# ============================================================
log_step "Step 5: Dispatch to jumpbox via SSM send-command"

CMD_ID=$(aws --profile ZoningInfoAdmin ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://$PARAMS_FILE" \
    --timeout-seconds "$POLL_TIMEOUT" \
    --comment "make ${SCRIPT_NAME}" \
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
log_info "(Ctrl-C to detach — command continues on jumpbox; check status with the CommandId above)"

start_time=$SECONDS
STATUS="Unknown"
while true; do
  elapsed=$(( SECONDS - start_time ))
  if [ "$elapsed" -gt "$POLL_TIMEOUT" ]; then
    echo
    log_error "Poll timeout (${POLL_TIMEOUT}s) exceeded."
    log_error "The command may still be running. Check with:"
    log_error "  aws --profile ZoningInfoAdmin ssm get-command-invocation \\"
    log_error "      --command-id $CMD_ID --instance-id $INSTANCE_ID --region $AWS_REGION"
    exit 1
  fi

  STATUS=$(aws --profile ZoningInfoAdmin ssm get-command-invocation \
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
# Step 7: Fetch and display stdout/stderr from the remote run
# ============================================================
log_step "Step 7: Remote script output"

printf '\n%b--- stdout ---%b\n' "$BLUE" "$NC"
aws --profile ZoningInfoAdmin ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text --region "$AWS_REGION" \
    2>/dev/null || echo "(no stdout captured)"

printf '\n%b--- stderr ---%b\n' "$BLUE" "$NC"
aws --profile ZoningInfoAdmin ssm get-command-invocation \
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
  log_info "  s3://$BUCKET_NAME/logs/$(date -u +%Y-%m-%d)/${SCRIPT_NAME}-*.log"
  log_info "Fetch with:  aws --profile ZI-Sandbox s3 cp s3://$BUCKET_NAME/logs/... -"
else
  log_error "Exit code non-zero due to Status: $STATUS"
  exit 1
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
