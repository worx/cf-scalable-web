#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# unpublish-dns: DELETE the Route 53 ALIAS A-record for the env's
# Drupal site-name. Companion to publish-dns.sh; use before destroy-all
# to leave a clean sub-zone, or any time you want the public URL to
# stop resolving.
#
# Route 53 DELETE on an alias record requires the AliasTarget to match
# what's currently stored EXACTLY. So this script reads the existing
# record verbatim and builds the DELETE change-batch from those bytes —
# the operator doesn't need to remember which ALB used to be there.
#
# Reads:
#   SSM     /<env>/drupal/site-name      → derives sub-zone name same way
#                                          publish-dns.sh does
#   Route53 existing record              → AliasTarget verbatim
#
# Writes:
#   Route53 DELETE of <site-name>. A record
#
# Idempotent: if no record exists, exits 0 with a noop message.
#
# Usage: scripts/unpublish-dns.sh <env>

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# --- 1. Site name + sub-zone (same derivation as publish-dns.sh) --------------
SITE_NAME=$(aws ssm get-parameter --name "/$ENV/drupal/site-name" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)
if [ -z "$SITE_NAME" ] || [ "$SITE_NAME" = "None" ]; then
  echo "WARN: /$ENV/drupal/site-name not in SSM — nothing to unpublish." >&2
  exit 0
fi

SUB_ZONE=$(echo "$SITE_NAME" | cut -d. -f2-)
if [ -z "$SUB_ZONE" ] || [ "$SUB_ZONE" = "$SITE_NAME" ]; then
  echo "WARN: site-name '$SITE_NAME' has no parent zone label — nothing to delete." >&2
  exit 0
fi

ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='$SUB_ZONE.'].Id | [0]" \
  --output text 2>/dev/null | sed 's|/hostedzone/||')
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "WARN: no hosted zone '$SUB_ZONE.' in this AWS account — nothing to delete." >&2
  exit 0
fi

# --- 2. Find the existing record (need its AliasTarget verbatim for DELETE) ---
EXISTING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='$SITE_NAME.' && Type=='A'] | [0]" \
  --output json 2>/dev/null || echo "null")

if [ "$EXISTING" = "null" ] || [ -z "$EXISTING" ]; then
  echo "✓ No A record for $SITE_NAME in zone $SUB_ZONE — nothing to do."
  exit 0
fi

# Confirm it's actually an alias record (we don't handle plain A records here —
# this script's contract is "undo publish-dns.sh", which always writes alias).
HAS_ALIAS=$(echo "$EXISTING" | jq -r '.AliasTarget // empty')
if [ -z "$HAS_ALIAS" ]; then
  echo "ERROR: existing record for $SITE_NAME is not an alias record." >&2
  echo "       This script only undoes alias records published by publish-dns.sh." >&2
  echo "       Use the AWS console or 'aws route53 change-resource-record-sets'" >&2
  echo "       directly to remove a non-alias record." >&2
  exit 1
fi

echo "Unpublishing DNS for env=$ENV:"
echo "  Site name:   $SITE_NAME"
echo "  Sub-zone:    $SUB_ZONE  (id=$ZONE_ID)"
echo "  Currently:   $(echo "$EXISTING" | jq -r '.AliasTarget.DNSName')"
echo ""

# --- 3. Build DELETE change-batch with the existing record verbatim -----------
BATCH=$(mktemp)
trap 'rm -f "$BATCH"' EXIT
jq -n --argjson rr "$EXISTING" '
{
  Changes: [{
    Action: "DELETE",
    ResourceRecordSet: $rr
  }]
}
' > "$BATCH"

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "file://$BATCH" \
  --query 'ChangeInfo.Id' --output text)

echo "✓ Route 53 DELETE submitted (ChangeId: $CHANGE_ID)"
echo "  $SITE_NAME will stop resolving within ~60s (depending on resolver cache)."
