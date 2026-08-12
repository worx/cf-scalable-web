#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/sync-s3-media-when-ready.sh
#
# Purpose:  Pre-warm sync-s3-media in parallel with deploy-all.
#           Waits for the storage-s3 CFN stack to reach CREATE_COMPLETE
#           (which creates the destination sandbox-drupal-media bucket),
#           then fires `make sync-s3-media CONFIRMED=yes`.
#
#           sync-s3-media itself is S3-to-S3 CopyObject server-side,
#           so it runs on the prod jumpbox as a pure API orchestrator.
#           This wrapper's whole job is to be the sequencing point:
#           "wait until sandbox has a destination bucket, then fire."
#
# Wall time context: sync-s3-media varies from ~3 min (small media
#                    library) to ~30+ min (many tens of thousands of
#                    PDFs). Running it in parallel with deploy-all
#                    (35-40 min) + subsequent phases (~35 min) means
#                    it has a ~70 min window to complete without
#                    blocking anything.
#
# Called from:  scripts/full-test-cycle.sh (backgrounded, wait'd for
#               right before smoke tests).
#
# Usage:    scripts/sync-s3-media-when-ready.sh [ENV]
#
# Arguments:
#   ENV     Target environment (default: sandbox)
#
# Environment variables:
#   POLL_INTERVAL  Seconds between stack-status polls (default: 15)
#   POLL_TIMEOUT   Seconds before giving up waiting for stack (default: 2400 = 40 min)
#
# Exit codes:
#   0  sync-s3-media completed successfully
#   1  storage-s3 stack wait timed out, or sync-s3-media failed
#
# Runs as:  operator with ZI-Sandbox profile (same as full-test-cycle.sh)
#
# Created:  2026-08-12
# ============================================================

set -euo pipefail

ENV="${1:-sandbox}"
STACK="cf-scalable-web-${ENV}-storage-s3"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-2400}"

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

ts() { date -u +%H:%M:%SZ; }

echo "[$(ts)] sync-s3-media-when-ready: ENV=$ENV STACK=$STACK"
echo "[$(ts)] Polling stack every ${POLL_INTERVAL}s, timeout ${POLL_TIMEOUT}s"

# ============================================================
# Wait for the storage-s3 stack. States we care about:
#   CREATE_COMPLETE / UPDATE_COMPLETE  -> destination bucket exists, proceed
#   *_IN_PROGRESS                      -> keep polling
#   NO_STACK_YET / not-yet-exists      -> keep polling (deploy-all just started)
#   ROLLBACK_* / *_FAILED              -> hard exit — nothing to sync into
# ============================================================
START_TIME=$SECONDS
DOT_COUNT=0
while true; do
  ELAPSED=$(( SECONDS - START_TIME ))
  if [ "$ELAPSED" -gt "$POLL_TIMEOUT" ]; then
    echo ""
    echo "[$(ts)] TIMEOUT after ${ELAPSED}s waiting for $STACK" >&2
    exit 1
  fi

  # AWS returns non-zero if the stack doesn't exist yet — that's fine,
  # keep polling. We treat both "stack missing" and "IN_PROGRESS" the
  # same: another sleep-poll cycle.
  STATUS=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "$STACK" \
    --query 'Stacks[0].StackStatus' --output text \
    --region us-east-1 2>/dev/null || echo "NO_STACK_YET")

  case "$STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      echo ""
      echo "[$(ts)] stack $STACK is $STATUS (after ${ELAPSED}s)"
      break
      ;;
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|REVIEW_IN_PROGRESS|NO_STACK_YET)
      DOT_COUNT=$((DOT_COUNT + 1))
      if [ $((DOT_COUNT % 10)) -eq 0 ]; then printf "|"
      elif [ $((DOT_COUNT % 5)) -eq 0 ]; then printf "+"
      else printf "."
      fi
      sleep "$POLL_INTERVAL"
      ;;
    *)
      echo ""
      echo "[$(ts)] stack $STACK has unexpected/failed status: $STATUS" >&2
      echo "[$(ts)] Cannot proceed — deploy-all likely failed on storage-s3." >&2
      exit 1
      ;;
  esac
done

# ============================================================
# Storage-s3 is ready. Fire sync-s3-media via the migration/ Makefile.
# The target itself SSM-dispatches to the prod jumpbox (which runs the
# actual `aws s3 sync` command). See migration/scripts/jumpbox/sync-s3-media.sh
# for the full flow.
#
# CONFIRMED=yes so the destructive-potential prompt is skipped for
# unattended runs.
# ============================================================
echo "[$(ts)] Firing: cd $REPO_ROOT/migration && make sync-s3-media CONFIRMED=yes"
cd "$REPO_ROOT/migration"
if make sync-s3-media CONFIRMED=yes; then
  echo "[$(ts)] sync-s3-media completed successfully"
  exit 0
else
  RC=$?
  echo "[$(ts)] sync-s3-media FAILED with exit code $RC" >&2
  exit "$RC"
fi

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
