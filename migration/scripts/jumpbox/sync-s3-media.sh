#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/sync-s3-media.sh
#
# Purpose:  aws s3 sync prod's Drupal media bucket (`zi-documents`)
#           directly into sandbox's media bucket
#           (`sandbox-drupal-media-kv-worxco`). No intermediate hop
#           through the migration bucket.
#
# Incremental: aws s3 sync only transfers objects that are new or
# modified since the last run. Second/third/Nth invocations pick up
# only prod's changes, not the whole bucket.
#
# One-direction: prod → sandbox. Never the other way. `--delete` is
# NOT set by default — deleting an object from prod won't delete it
# on sandbox. Enable `DELETE_ORPHANED=yes` if you want strict mirror.
#
# Flow (four phases):
#   1. Preconditions       (aws CLI, source + target reachable)
#   2. Confirmation        (destructive potential; honors CONFIRMED=yes)
#   3. sync source → target  (aws s3 sync)
#   4. Report             (transferred bytes, elapsed)
#
# Cross-account mechanics:
#   - Runs on the PROD jumpbox (this script).
#   - Reads from `zi-documents` in prod account via jumpbox's IAM role
#     (native, no cross-account needed).
#   - Writes to `sandbox-drupal-media-kv-worxco` in sandbox account
#     via a bucket policy on the sandbox side allowing the prod
#     jumpbox role. Same principal-scoping pattern as
#     cf-migration-bucket.yaml.
#   - Enabled by the CFN change in cf-storage-s3.yaml
#     (MigrationSourceAccountId + MigrationSourceRoleArnPattern
#     parameters set on sandbox).
#
# Idempotent: yes. Second run only transfers deltas.
#
# Environment variables (all optional, listed with defaults):
#   PROD_BUCKET       Source bucket in prod account   (zi-documents)
#   SANDBOX_BUCKET    Target bucket in sandbox        (sandbox-drupal-media-kv-worxco)
#   PROD_REGION       Region of source bucket         (us-east-1)
#   SANDBOX_REGION    Region of target bucket         (us-east-1)
#   INCLUDE           `--include` glob (optional)
#   EXCLUDE           `--exclude` glob (optional)
#   DELETE_ORPHANED   yes = pass --delete to aws s3 sync (strict mirror)
#   CONFIRMED         yes = skip Y/N confirmation
#   DRY_RUN           yes = pass --dryrun to aws s3 sync (preview only)
#
# Runs as:  root on the jumpbox
# Host:     Prod jumpbox
# Called by:
#   - Directly (in an SSM interactive session, `sudo ./sync-s3-media.sh`)
#   - By `make sync-s3-media` (dispatches via _ssm-run-jumpbox.sh)
#
# Created:  2026-07-21

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../_common.sh"

# ============================================================
# Configuration defaults
# ============================================================
PROD_BUCKET="${PROD_BUCKET:-zi-documents}"
SANDBOX_BUCKET="${SANDBOX_BUCKET:-sandbox-drupal-media-kv-worxco}"
PROD_REGION="${PROD_REGION:-us-east-1}"
SANDBOX_REGION="${SANDBOX_REGION:-us-east-1}"

# ============================================================
# Set up logging + on-exit S3 upload of THIS script's log
# ============================================================
log_init "sync-s3-media"
# Log gets uploaded to the MIGRATION BUCKET on the sandbox side —
# same location as other migration scripts' logs so post-mortems
# have one place to look. MIGRATION_BUCKET is passed in via SSM env
# by _ssm-run-jumpbox.sh.
trap 'log_upload_and_exit "${MIGRATION_BUCKET:-}"' EXIT

log_step "sync-s3-media — prod → sandbox media bucket"
log_info "PROD_BUCKET      = $PROD_BUCKET"
log_info "SANDBOX_BUCKET   = $SANDBOX_BUCKET"
log_info "PROD_REGION      = $PROD_REGION"
log_info "SANDBOX_REGION   = $SANDBOX_REGION"
log_info "DELETE_ORPHANED  = ${DELETE_ORPHANED:-no}"
log_info "DRY_RUN          = ${DRY_RUN:-no}"

# ============================================================
# Phase 1 of 4: Preconditions
# ============================================================
log_step "Phase 1/4: Preconditions"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root (use sudo)."
  exit 1
fi

for tool in aws stat; do
  command -v "$tool" >/dev/null 2>&1 \
    || { log_error "Required tool '$tool' not found on PATH."; exit 1; }
done
log_ok "All required tools available"

# Source bucket read check — should succeed via jumpbox's IAM role
if ! aws s3 ls "s3://$PROD_BUCKET/" --region "$PROD_REGION" \
     --max-items 1 >/dev/null 2>&1; then
  log_error "Cannot read from source bucket s3://$PROD_BUCKET/ in $PROD_REGION."
  log_info  "Check jumpbox IAM role has s3:ListBucket + s3:GetObject on $PROD_BUCKET."
  exit 1
fi
log_ok "Source bucket readable: s3://$PROD_BUCKET/"

# Target bucket write check — should succeed via cross-account bucket policy
# Try a HEAD on the bucket (ListBucket permission). Full write test is
# expensive; we trust the sync's error output if the bucket policy is
# misconfigured.
if ! aws s3 ls "s3://$SANDBOX_BUCKET/" --region "$SANDBOX_REGION" \
     --max-items 1 >/dev/null 2>&1; then
  log_error "Cannot list target bucket s3://$SANDBOX_BUCKET/ in $SANDBOX_REGION."
  log_info  "Check sandbox's cf-storage-s3 stack has the cross-account bucket policy."
  log_info  "Redeploy with: make deploy-storage-s3 ENV=sandbox"
  log_info  "Verify:        aws --profile ZI-Sandbox s3api get-bucket-policy \\"
  log_info  "                 --bucket $SANDBOX_BUCKET --query Policy --output text | jq"
  exit 1
fi
log_ok "Target bucket accessible: s3://$SANDBOX_BUCKET/"

# ============================================================
# Phase 2 of 4: Confirmation
# ============================================================
log_step "Phase 2/4: Confirmation"

# Approximate source size for the confirmation prompt. Use --summarize.
log_info "Computing source size (may take a moment on a large bucket)..."
SIZE_RAW=$(aws s3 ls "s3://$PROD_BUCKET/" --recursive --summarize \
  --region "$PROD_REGION" 2>/dev/null | tail -2 || echo "")
if [ -n "$SIZE_RAW" ]; then
  log_info "$SIZE_RAW"
fi

confirm_or_exit "About to sync media from prod to sandbox:
    Source: s3://$PROD_BUCKET/       ($PROD_REGION, jumpbox's IAM role)
    Target: s3://$SANDBOX_BUCKET/    ($SANDBOX_REGION, cross-account bucket policy)
    Delete orphaned in target: ${DELETE_ORPHANED:-no}
    Dry-run: ${DRY_RUN:-no}
    First run transfers everything; subsequent runs are incremental."

# ============================================================
# Phase 3 of 4: sync
# ============================================================
log_step "Phase 3/4: aws s3 sync"

SYNC_ARGS=(
  "s3://$PROD_BUCKET/"
  "s3://$SANDBOX_BUCKET/"
  --source-region "$PROD_REGION"
  --region "$SANDBOX_REGION"
)
[ "${DELETE_ORPHANED:-}" = "yes" ] && SYNC_ARGS+=(--delete)
[ "${DRY_RUN:-}" = "yes" ]         && SYNC_ARGS+=(--dryrun)
[ -n "${INCLUDE:-}" ] && SYNC_ARGS+=(--include "$INCLUDE")
[ -n "${EXCLUDE:-}" ] && SYNC_ARGS+=(--exclude "$EXCLUDE")

log_info "Running: aws s3 sync ${SYNC_ARGS[*]}"
time_start=$SECONDS
aws s3 sync "${SYNC_ARGS[@]}"
time_elapsed=$(( SECONDS - time_start ))
log_ok "sync completed in ${time_elapsed}s"

# ============================================================
# Phase 4 of 4: Report
# ============================================================
log_step "Phase 4/4: Post-sync summary"

log_info "Target bucket contents (first 10 keys):"
aws s3 ls "s3://$SANDBOX_BUCKET/" --recursive --region "$SANDBOX_REGION" \
  2>/dev/null | head -10 || true

log_ok "sync-s3-media complete"
log_info "Next: verify Drupal serves images / PDFs against sandbox bucket"
log_info "      (requires flysystem AWS_S3_BUCKET env var set to $SANDBOX_BUCKET"
log_info "       via configure-php.sh — see next commit in this feature set)"
