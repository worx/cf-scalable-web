#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/_ssm-run-deploy-host.sh
#
# Purpose:  Internal orchestrator for the `make dispatch-*` targets.
#           Uploads a migration/scripts/deploy-host/<name>.sh script
#           + _common.sh to the sandbox migration S3 bucket, then uses
#           `aws ssm send-command` to have the sandbox deploy-host
#           download and execute it. Polls for completion and displays
#           stdout/stderr.
#
#           Walk-away safe — the remote command runs in SSM's own runner,
#           surviving Mac-side interrupts (session timeout, sleep, lid
#           close). Suitable for hours-long operations like run-pgloader.
#
#           The prefix `_` on the filename indicates this is a helper
#           called by Makefile targets, not invoked directly by operators.
#
#           Mirror of migration/scripts/_ssm-run-jumpbox.sh but simpler:
#           single account (sandbox), no cross-account credential dance.
#
# Usage:    _ssm-run-deploy-host.sh <script-name>
#           where <script-name> matches migration/scripts/deploy-host/<name>.sh
#
# Runs as:  operator on Mac (or deploy-host itself — anywhere with
#           ZI-Sandbox profile access + SSM permissions)
#
# Environment variables (Makefile passes real values; direct callers
# get sane defaults):
#   AWS_REGION            Region for all ops              (us-east-1)
#   BUCKET_STACK          Migration bucket CFN stack      (cf-scalable-web-sandbox-migration-bucket)
#   DEPLOY_HOST_STACK     Deploy-host CFN stack           (cf-deploy-host)
#   CONFIRMED             yes = skip remote confirm prompt
#   DRY_RUN               yes = tell remote script to dry-run
#   MIGRATION_DB_NAME     Passed through to run-pgloader  (zinew)
#   PGLOADER_HEAP_MB      Passed through to run-pgloader  (4096)
#   POLL_INTERVAL         Seconds between status polls    (30)
#   POLL_TIMEOUT          Seconds before giving up        (7200 = 2h)
#
# Behavior:
#   - Sources migration/scripts/_common.sh for colors + log_* helpers
#   - Does NOT call log_init (no local log file — real logs land on
#     deploy-host and get uploaded to s3://…/logs/ by the remote script's
#     own log_upload_and_exit trap)
#   - Ctrl-C during polling detaches; the remote command keeps running.
#     Check status later with:
#       aws --profile ZI-Sandbox ssm get-command-invocation \
#         --command-id <ID> --instance-id <INSTANCE>
#
# Created:  2026-07-17
# ============================================================

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

if [ $# -ne 1 ]; then
  log_error "Usage: $0 <script-name>"
  log_error "  Example: $0 restore-mysql"
  exit 2
fi
SCRIPT_NAME="$1"

# Local logging + on-exit S3 upload. Log lives in /var/log/worxco-migration
# (Linux) or /tmp/worxco-migration (Mac). BUCKET_NAME is resolved via
# CFN below — the trap fires even if resolution fails (empty bucket =
# skip upload but keep local log).
log_init "_ssm-run-deploy-host-$SCRIPT_NAME"
trap 'log_upload_and_exit "${BUCKET_NAME:-}"' EXIT
LOCAL_SCRIPT="scripts/deploy-host/${SCRIPT_NAME}.sh"

if [ ! -f "$LOCAL_SCRIPT" ]; then
  log_error "Local script not found: $LOCAL_SCRIPT"
  log_error "  cwd: $(pwd)"
  log_error "  Are you running from the migration/ directory?"
  exit 2
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_STACK="${BUCKET_STACK:-cf-scalable-web-sandbox-migration-bucket}"
DEPLOY_HOST_STACK="${DEPLOY_HOST_STACK:-cf-deploy-host}"
CONFIRMED="${CONFIRMED:-}"
DRY_RUN="${DRY_RUN:-}"
MIGRATION_DB_NAME="${MIGRATION_DB_NAME:-}"
PGLOADER_HEAP_MB="${PGLOADER_HEAP_MB:-}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
POLL_TIMEOUT="${POLL_TIMEOUT:-7200}"

log_step "_ssm-run-deploy-host — orchestrating '$SCRIPT_NAME'"
log_info "AWS_REGION         = $AWS_REGION"
log_info "BUCKET_STACK       = $BUCKET_STACK"
log_info "DEPLOY_HOST_STACK  = $DEPLOY_HOST_STACK"
log_info "CONFIRMED          = ${CONFIRMED:-<unset>}"
log_info "DRY_RUN            = ${DRY_RUN:-<unset>}"
log_info "MIGRATION_DB_NAME  = ${MIGRATION_DB_NAME:-<default>}"
log_info "PGLOADER_HEAP_MB   = ${PGLOADER_HEAP_MB:-<default>}"
log_info "POLL_TIMEOUT       = ${POLL_TIMEOUT}s"

# ============================================================
# Step 1: Look up sandbox migration bucket
# ============================================================
log_step "Step 1: Look up migration bucket"

BUCKET_NAME=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "$BUCKET_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  log_error "Migration bucket stack '$BUCKET_STACK' not deployed."
  log_error "  Deploy first: cd migration && make deploy-bucket"
  exit 1
fi
log_ok "Bucket: $BUCKET_NAME"

# ============================================================
# Step 2: Look up sandbox deploy-host instance ID
# ============================================================
log_step "Step 2: Look up deploy-host instance ID"

INSTANCE_ID=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "$DEPLOY_HOST_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='DeployHostInstanceId'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  log_error "Deploy-host stack '$DEPLOY_HOST_STACK' not deployed."
  log_error "  Deploy first (from repo root): make deploy-deploy-host"
  exit 1
fi
log_ok "Deploy-host: $INSTANCE_ID"

# ============================================================
# Step 3: Upload scripts to S3
# ============================================================
log_step "Step 3: Upload scripts to s3://$BUCKET_NAME/scripts/"

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
    "s3://$BUCKET_NAME/scripts/deploy-host/${SCRIPT_NAME}.sh" \
    --region "$AWS_REGION" --quiet
log_ok "Uploaded ${SCRIPT_NAME}.sh"

# ============================================================
# Step 3b: Upload script-specific auxiliary files
# ============================================================
# Some remote scripts need companion files:
#   run-pgloader → migration/pgloader/zinew.load.tmpl (envsubst template)
# Extend this block if future scripts pick up other deps.
EXTRA_DOWNLOAD_CMDS=""
case "$SCRIPT_NAME" in
  run-pgloader)
    if [ ! -f "pgloader/zinew.load.tmpl" ]; then
      log_error "pgloader/zinew.load.tmpl not found (cwd: $(pwd))"
      log_error "  Are you running from the migration/ directory?"
      exit 1
    fi
    aws --profile ZI-Sandbox s3 cp pgloader/zinew.load.tmpl \
        "s3://$BUCKET_NAME/scripts/pgloader/zinew.load.tmpl" \
        --region "$AWS_REGION" --quiet
    log_ok "Uploaded pgloader/zinew.load.tmpl"
    # Build the extra download commands to inject into the SSM
    # inner script. These land the template at the exact path
    # run-pgloader.sh's default TEMPLATE_PATH lookup expects:
    # /opt/migration/pgloader/zinew.load.tmpl
    # (from REPO_MIGRATION_DIR="$(readlink -f $SCRIPT_DIR/../..)"
    # in run-pgloader.sh:69, which resolves to /opt/migration).
    EXTRA_DOWNLOAD_CMDS='mkdir -p /opt/migration/pgloader && aws s3 cp "s3://'"$BUCKET_NAME"'/scripts/pgloader/zinew.load.tmpl" /opt/migration/pgloader/zinew.load.tmpl --quiet'
    ;;
esac

# ============================================================
# Step 4: Build SSM send-command parameters
# ============================================================
log_step "Step 4: Build SSM command parameters"

PARAMS_FILE=$(mktemp)
trap 'rm -f "$PARAMS_FILE"' EXIT

# Preserving relative structure: run-pgloader.sh sources ../_common.sh
# so both files land in matching paths on the deploy-host:
#   /opt/migration/scripts/_common.sh
#   /opt/migration/scripts/deploy-host/run-pgloader.sh
#
# SSM AWS-RunShellScript uses /bin/sh (dash), which doesn't support
# `-o pipefail`. Using `-eu` (POSIX) here; the actual downloaded script
# has its own bash `set -euo pipefail`.
#
# Env vars are threaded through as `env KEY=VAL ... /path/to/script`.
# Unset locals ('') fall through as empty strings — remote script's
# defaults apply per its own `${VAR:-default}` fallbacks.
jq -n \
    --arg bucket "$BUCKET_NAME" \
    --arg script "$SCRIPT_NAME" \
    --arg confirmed "$CONFIRMED" \
    --arg dryrun "$DRY_RUN" \
    --arg db "$MIGRATION_DB_NAME" \
    --arg heap "$PGLOADER_HEAP_MB" \
    --arg extra "$EXTRA_DOWNLOAD_CMDS" \
    '{
      commands: [
        "set -eu",
        "mkdir -p /opt/migration/scripts/deploy-host",
        ("aws s3 cp \"s3://" + $bucket + "/scripts/_common.sh\" /opt/migration/scripts/_common.sh --quiet"),
        ("aws s3 cp \"s3://" + $bucket + "/scripts/deploy-host/" + $script + ".sh\" /opt/migration/scripts/deploy-host/" + $script + ".sh --quiet"),
        ("chmod +x /opt/migration/scripts/deploy-host/" + $script + ".sh"),
        (if $extra != "" then $extra else "true" end),
        ("env CONFIRMED=\"" + $confirmed + "\" DRY_RUN=\"" + $dryrun + "\" MIGRATION_BUCKET=\"" + $bucket + "\" MIGRATION_DB_NAME=\"" + $db + "\" PGLOADER_HEAP_MB=\"" + $heap + "\" /opt/migration/scripts/deploy-host/" + $script + ".sh")
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
    --comment "make dispatch-${SCRIPT_NAME}" \
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
log_info "(Ctrl-C to detach — command continues on deploy-host)"
log_info "Later: aws --profile ZI-Sandbox ssm get-command-invocation \\"
log_info "         --command-id $CMD_ID --instance-id $INSTANCE_ID --region $AWS_REGION"

start_time=$SECONDS
STATUS="Unknown"
while true; do
  elapsed=$(( SECONDS - start_time ))
  if [ "$elapsed" -gt "$POLL_TIMEOUT" ]; then
    echo
    log_error "Poll timeout (${POLL_TIMEOUT}s) exceeded."
    log_error "The command may still be running. Check with the CommandId above."
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
  log_info "  s3://$BUCKET_NAME/logs/$(date -u +%Y-%m-%d)/${SCRIPT_NAME}-*.log"
  log_info "Fetch with:  aws --profile ZI-Sandbox s3 cp s3://$BUCKET_NAME/logs/... -"
else
  log_error "Exit code non-zero due to Status: $STATUS"
  exit 1
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
