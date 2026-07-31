#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/purge-versioned-bucket.sh
#
# Purpose: Fully empty an S3 bucket — including every object version AND
# every delete marker — so that CloudFormation can subsequently delete
# the bucket without hitting the "bucket not empty" error that stops it
# from deleting versioned buckets.
#
# Why this script exists (bug caught 2026-07-29):
# The Makefile's `destroy-storage-s3` had inline purge logic that made a
# SINGLE `list-object-versions` call, which caps at 1000 items per
# response. On a bucket with more (e.g., sandbox-drupal-media-kv-worxco
# had 5535 delete markers after sync-s3-media runs), it purged only the
# first 1000 and left the rest, so CFN's subsequent delete-stack failed
# with DELETE_FAILED on the bucket.
#
# This script paginates properly — loops list → delete → list → delete
# until the bucket returns zero versions AND zero delete markers.
#
# Usage:  scripts/purge-versioned-bucket.sh BUCKET_NAME
# Env:    AWS_PROFILE, AWS_REGION (respected via inheritance)
#
# Idempotent — if the bucket doesn't exist, exits 0 with a note.
# Safe by default — only removes objects/versions/markers; the bucket
# itself remains for the caller (CFN, aws s3 rb, etc.) to delete.
#
# Created: 2026-07-29

set -euo pipefail

BUCKET="${1:-}"
if [ -z "$BUCKET" ]; then
  echo "Usage: $0 BUCKET_NAME" >&2
  exit 2
fi

# Check bucket exists first — idempotent on "already gone" scenarios
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "  Bucket '$BUCKET' does not exist — nothing to purge"
  exit 0
fi

PAYLOAD=$(mktemp)
trap "rm -f $PAYLOAD" EXIT

TOTAL=0
ROUND=0
MAX_ROUNDS=200  # safety cap — well over what a real bucket would need

while true; do
  ROUND=$((ROUND + 1))

  # --max-keys 500: half of delete-objects' 1000-item cap, so we can
  # combine Versions + DeleteMarkers in the same delete call without
  # exceeding the limit. --output json to feed jq cleanly.
  RESPONSE=$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --max-keys 500 \
    --output json)

  V_COUNT=$(echo "$RESPONSE" | jq '(.Versions // []) | length')
  M_COUNT=$(echo "$RESPONSE" | jq '(.DeleteMarkers // []) | length')

  if [ "$V_COUNT" = "0" ] && [ "$M_COUNT" = "0" ]; then
    break
  fi

  # Build combined delete payload — versions + delete markers, both
  # need explicit VersionId to be removable. Quiet:true suppresses
  # a per-object success list in the response (keeps output clean).
  echo "$RESPONSE" | jq '{Objects: (((.Versions // []) + (.DeleteMarkers // [])) | map({Key, VersionId})), Quiet: true}' > "$PAYLOAD"

  aws s3api delete-objects \
    --bucket "$BUCKET" \
    --delete "file://$PAYLOAD" \
    --output json > /dev/null

  TOTAL=$((TOTAL + V_COUNT + M_COUNT))
  echo "  round $ROUND: purged $V_COUNT versions + $M_COUNT delete markers (cumulative: $TOTAL)"

  if [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
    echo "  ERROR: over $MAX_ROUNDS rounds — bucket may be receiving new writes" >&2
    echo "         or list-delete race condition. Investigate manually." >&2
    exit 1
  fi
done

echo "  Purged $TOTAL total items from '$BUCKET' (over $ROUND round(s))"
