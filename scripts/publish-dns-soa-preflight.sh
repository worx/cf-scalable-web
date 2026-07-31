#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# publish-dns-soa-preflight: Ensure the parent DNS zone's SOA MINIMUM
# (negative-cache TTL, per RFC 2308) is 300 seconds instead of Route
# 53's default 86400 (24 hours).
#
# Why: sandbox / staging / any non-prod env gets destroyed and re-deployed
# on cadence. During the destroy → deploy window, resolvers get NXDOMAIN
# for the env's record and cache "no such record" for the SOA MINIMUM
# duration. With Route 53's 86400 default, that's 24 HOURS of "why doesn't
# my URL work" after every rebuild. Lowering to 300 aligns negative-cache
# with the record's own 5-min TTL.
#
# Production is EXPLICITLY skipped — SOA MIN of 300 doesn't hurt prod
# functionally (prod records never disappear so the negative-cache is
# irrelevant), but Kurt's explicit policy 2026-07-31 is "leave production
# alone." Honored here.
#
# Idempotent: if SOA MIN is already 300 (or less), does nothing.
# If different, UPSERTs and bumps the SOA serial.
#
# Usage: publish-dns-soa-preflight.sh <env>
# Requires: aws CLI, jq, ZI-Sandbox profile (or whatever the env uses)
#
# Zone discovery: same logic as publish-dns.sh — read
# /<env>/drupal/site-name from SSM, derive zone name by dropping the
# leftmost label (sandbox.envs.zoning-info.com → envs.zoning-info.com),
# find hosted zone matching that name in the current AWS account.
#
# Created: 2026-07-31

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# Production: skip entirely per policy.
if [ "$ENV" = "production" ]; then
  echo "  SOA preflight SKIPPED for env=production (per policy)"
  exit 0
fi

TARGET_MIN=300

echo "  SOA preflight for env=$ENV (target MINIMUM=$TARGET_MIN)"

# Look up the env's site-name from SSM
SITE_NAME=$(aws ssm get-parameter \
  --name "/$ENV/drupal/site-name" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")

if [ -z "$SITE_NAME" ] || [ "$SITE_NAME" = "None" ]; then
  echo "  WARN: /$ENV/drupal/site-name not in SSM — skipping SOA preflight" >&2
  exit 0
fi

# Derive zone name — drop the leftmost label. Handles trailing dot.
ZONE_NAME="${SITE_NAME#*.}"
ZONE_NAME="${ZONE_NAME%.}"
echo "  Site name:  $SITE_NAME"
echo "  Zone name:  $ZONE_NAME"

# Find the hosted zone. Route 53 zone names include a trailing dot;
# list-hosted-zones-by-name returns them that way.
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$ZONE_NAME." \
  --query "HostedZones[?Name=='$ZONE_NAME.'].Id" \
  --output text 2>/dev/null | head -1)

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "  WARN: No hosted zone found for $ZONE_NAME — skipping SOA preflight" >&2
  exit 0
fi
echo "  Zone ID:    $ZONE_ID"

# Get the current SOA. Route 53 SOA value is a single string like:
#   "ns-517.awsdns-00.net. awsdns-hostmaster.amazon.com. 2 7200 900 1209600 300"
# The 5 numbers are: serial refresh retry expire minimum.
SOA=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='SOA'].ResourceRecords[0].Value" \
  --output text 2>/dev/null)

if [ -z "$SOA" ]; then
  echo "  WARN: Couldn't read SOA record for $ZONE_NAME — skipping" >&2
  exit 0
fi

# Parse: last 5 fields are the SOA numbers, last of those is MINIMUM.
CURRENT_MIN=$(echo "$SOA" | awk '{print $NF}')
echo "  Current SOA MINIMUM: $CURRENT_MIN"

if [ "$CURRENT_MIN" -le "$TARGET_MIN" ] 2>/dev/null; then
  echo "  ✓ SOA MINIMUM already $CURRENT_MIN (≤ target $TARGET_MIN) — no change needed"
  exit 0
fi

echo "  → Lowering SOA MINIMUM $CURRENT_MIN → $TARGET_MIN"

# Bump serial (first of the 5 numbers) and replace MINIMUM.
# Assemble new SOA value.
SERIAL=$(echo "$SOA" | awk '{print $(NF-4)}')
REFRESH=$(echo "$SOA" | awk '{print $(NF-3)}')
RETRY=$(echo "$SOA" | awk '{print $(NF-2)}')
EXPIRE=$(echo "$SOA" | awk '{print $(NF-1)}')
# Everything BEFORE the 5 numbers is the SOA MNAME + RNAME (2 fields).
# Rebuild by taking the first two fields plus new numbers.
NS_HOSTMASTER=$(echo "$SOA" | awk '{print $1, $2}')
NEW_SERIAL=$((SERIAL + 1))
NEW_SOA="$NS_HOSTMASTER $NEW_SERIAL $REFRESH $RETRY $EXPIRE $TARGET_MIN"

echo "  New SOA: $NEW_SOA"

# Fire the UPSERT.
CHANGE=$(mktemp)
trap 'rm -f "$CHANGE"' EXIT
cat > "$CHANGE" <<EOF
{
  "Comment": "SOA MIN $CURRENT_MIN→$TARGET_MIN (publish-dns-soa-preflight, env=$ENV)",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$ZONE_NAME.",
      "Type": "SOA",
      "TTL": 900,
      "ResourceRecords": [{"Value": "$NEW_SOA"}]
    }
  }]
}
EOF

RESULT=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "file://$CHANGE" \
  --query 'ChangeInfo.Status' --output text 2>&1)

echo "  ✓ SOA UPSERTed (change status: $RESULT)"
