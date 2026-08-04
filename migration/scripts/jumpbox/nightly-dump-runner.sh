#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/nightly-dump-runner.sh
#
# Purpose:  Cron-friendly wrapper that runs all four dump-* scripts
#           in sequence, notifies via SNS on failure. Designed to be
#           invoked by crontab on the jumpbox at a scheduled time
#           (default: 3 AM UTC, Tue-Sat).
#
# Flow:
#   1. Sync latest scripts from s3://<bucket>/scripts/ to local
#      /opt/migration/scripts/ so cron always uses the current versions
#      (uploaded by the human running `make dump-*` from Mac/deploy-host)
#   2. Run each of dump-mysql, dump-codebase, dump-files, dump-private
#      in sequence with CONFIRMED=yes
#   3. Break on first failure (subsequent dumps are usually pointless
#      if an earlier one failed)
#   4. If any step failed AND an SNS topic ARN is configured (via SSM
#      param /migration/nightly-cron/sns-topic-arn), publish a failure
#      notification with the failing step + last 80 log lines
#
# Env vars (all optional):
#   MIGRATION_BUCKET   Sandbox S3 bucket (default: sandbox-migration-kv-worxco)
#
# SSM parameter (optional):
#   /migration/nightly-cron/sns-topic-arn   ARN of SNS topic for failure
#                                            notifications; empty/absent
#                                            = no notification (log only)
#
# Runs as:  root on the jumpbox, invoked by crontab
# Host:     Prod jumpbox (EC2, prod account)
# Called by: crontab entry installed by install-nightly-cron.sh
#            (also runnable manually: sudo /opt/nightly-dumps/nightly-dump-runner.sh)
#
# Logging:  Written to /var/log/worxco-migration/nightly-<UTC>.log
#           Old logs accumulate; consider adding to logrotate.
#
# Created:  2026-08-04

set -uo pipefail

MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
SCRIPTS_DIR="/opt/migration/scripts"
LOG_DIR="/var/log/worxco-migration"
STAMP=$(date -u +%Y%m%d-%H%M%SZ)
LOG_FILE="$LOG_DIR/nightly-$STAMP.log"

mkdir -p "$LOG_DIR"

# Send all subsequent output to log file AND stdout (so cron redirect works).
# `exec > >(tee ...)` runs the tee in a background process but keeps this
# script in the main shell — variables set below survive the redirect,
# unlike the `{ ... } | tee` pattern which runs the block in a subshell.
exec > >(tee "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# Look up SNS topic ARN from SSM (best-effort)
# ------------------------------------------------------------
SNS_TOPIC_ARN=$(aws ssm get-parameter \
  --name /migration/nightly-cron/sns-topic-arn \
  --query 'Parameter.Value' --output text --region us-east-1 2>/dev/null || echo "")

# ------------------------------------------------------------
# Notification helper
# ------------------------------------------------------------
notify_failure() {
  local step="$1"
  local rc="$2"
  local subject="[nightly-dump FAILED] $(date +%Y-%m-%d) $step"
  local last_lines
  last_lines=$(tail -80 "$LOG_FILE" 2>/dev/null || echo "(log file unreadable)")
  local message="Nightly dump run FAILED on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ).

Failing step: $step
Exit code:    $rc

Full log on jumpbox: $LOG_FILE

Last 80 lines:
$last_lines"

  if [ -n "$SNS_TOPIC_ARN" ]; then
    if aws sns publish --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" --message "$message" \
        --region us-east-1 >/dev/null 2>&1; then
      echo "  → SNS notification sent to $SNS_TOPIC_ARN"
    else
      echo "  → SNS notification FAILED (topic=$SNS_TOPIC_ARN)"
    fi
  else
    echo "  → No SNS_TOPIC_ARN configured; failure logged only"
    echo "  → To enable notifications:"
    echo "        aws ssm put-parameter --name /migration/nightly-cron/sns-topic-arn \\"
    echo "          --value <topic-arn> --type String --overwrite --region us-east-1"
  fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
echo "=== nightly-dump-runner @ $STAMP ==="
echo "  host:              $(hostname)"
echo "  MIGRATION_BUCKET:  $MIGRATION_BUCKET"
echo "  SNS_TOPIC_ARN:     ${SNS_TOPIC_ARN:-(none)}"
echo "  log file:          $LOG_FILE"

echo ""
echo "--- Sync latest scripts from s3://$MIGRATION_BUCKET/scripts/ ---"
mkdir -p "$SCRIPTS_DIR/jumpbox"
aws s3 sync "s3://$MIGRATION_BUCKET/scripts/" "$SCRIPTS_DIR/" --exact-timestamps --no-progress
chmod +x "$SCRIPTS_DIR/jumpbox/"*.sh 2>/dev/null || true
echo "✓ scripts synced"

FAILED_STEP=""
FAILED_RC=0
for step in dump-mysql dump-codebase dump-files dump-private; do
  echo ""
  echo "=========================================="
  echo "=== Step: $step"
  echo "=========================================="
  if env CONFIRMED=yes MIGRATION_BUCKET="$MIGRATION_BUCKET" \
      bash "$SCRIPTS_DIR/jumpbox/$step.sh"; then
    echo "  ✓ $step OK"
  else
    FAILED_RC=$?
    FAILED_STEP="$step"
    echo ""
    echo "  ✗ $step FAILED (exit $FAILED_RC)"
    echo ""
    echo "=== ABORTING nightly-dump-runner (remaining steps skipped) ==="
    break
  fi
done

echo ""
echo "=========================================="
if [ -z "$FAILED_STEP" ]; then
  echo "=== ALL 4 DUMPS COMPLETE @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "=========================================="
  exit 0
else
  echo "=== FAILURE @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "=========================================="
  notify_failure "$FAILED_STEP" "$FAILED_RC"
  exit "$FAILED_RC"
fi
