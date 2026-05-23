#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# publish-dns: UPSERT a Route 53 ALIAS A-record pointing the env's
# Drupal site-name at its ALB.
#
# Reads:
#   SSM     /<env>/drupal/site-name          → e.g. sandbox.envs.zoning-info.com
#   CFN     cf-scalable-web-<env>-compute-alb
#             - ALBDnsName                   → e.g. sandbox-alb-XXXX.us-east-1.elb.amazonaws.com
#             - ALBHostedZoneId              → ALB's regional canonical zone (Z35SXDOTRQ7X7K for us-east-1)
#   Route53 hosted zones in this account     → finds the sub-zone matching
#                                              everything after the first label
#                                              of <site-name>
#
# Writes:
#   Route53 ALIAS A record  <site-name>.  →  <alb-dns>   (in the sub-zone)
#
# Why this is a script + a docs runbook, not pure CloudFormation:
#   - The parent hosted zone lives in a DIFFERENT AWS account (the org
#     parent) — stack-bound DNS records would either need cross-account
#     IAM (fragile) or hard-code the parent zone (anti-portability).
#   - Different deployments of this codebase will use entirely different
#     domains. Hard-coding "envs.zoning-info.com" anywhere in the stack
#     would lock the project to one operator's setup.
# So: the one-time sub-zone delegation is operator-documented (see
# docs/DNS-SETUP.md), and the per-env record update is this script,
# fully driven by what's already in SSM and CFN outputs.
#
# Usage: scripts/publish-dns.sh <env>

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# --- 1. Site name from SSM ----------------------------------------------------
SITE_NAME=$(aws ssm get-parameter --name "/$ENV/drupal/site-name" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)
if [ -z "$SITE_NAME" ] || [ "$SITE_NAME" = "None" ]; then
  echo "ERROR: /$ENV/drupal/site-name not in SSM." >&2
  echo "       Run 'make deploy-app-drupal ENV=$ENV' first — that stack" >&2
  echo "       writes the SSM parameter this script depends on." >&2
  exit 1
fi

# Reserved/non-routable TLDs will never resolve publicly. Refuse early so the
# operator updates app-drupal-<env>.json instead of publishing a dead record.
case "$SITE_NAME" in
  *.test|*.local|*.localhost|*.invalid|*.example|*.example.com|*.example.net|*.example.org)
    echo "ERROR: site-name '$SITE_NAME' uses a reserved/non-routable TLD." >&2
    echo "       Update cloudformation/parameters/app-drupal-$ENV.json to a real" >&2
    echo "       FQDN, run 'make deploy-app-drupal ENV=$ENV', then retry." >&2
    exit 1
    ;;
esac

# --- 2. Derive sub-zone (everything after the first label) --------------------
# sandbox.envs.zoning-info.com  →  envs.zoning-info.com
SUB_ZONE=$(echo "$SITE_NAME" | cut -d. -f2-)
if [ -z "$SUB_ZONE" ] || [ "$SUB_ZONE" = "$SITE_NAME" ]; then
  echo "ERROR: site-name '$SITE_NAME' has no parent zone label — needs at least" >&2
  echo "       host.domain.tld for the sub-zone derivation to work." >&2
  exit 1
fi

# --- 3. Find the sub-zone's hosted-zone ID in this AWS account ----------------
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='$SUB_ZONE.'].Id | [0]" \
  --output text 2>/dev/null | sed 's|/hostedzone/||')
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "ERROR: no hosted zone '$SUB_ZONE.' in this AWS account." >&2
  echo "       Has the sub-zone been delegated from the parent? See" >&2
  echo "       docs/DNS-SETUP.md for the one-time setup procedure." >&2
  exit 1
fi

# --- 4. ALB info from the compute-alb stack -----------------------------------
ALB_STACK="cf-scalable-web-$ENV-compute-alb"
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "$ALB_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text 2>/dev/null || true)
ALB_ZONE=$(aws cloudformation describe-stacks \
  --stack-name "$ALB_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBHostedZoneId'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
  echo "ERROR: could not read ALBDnsName from $ALB_STACK." >&2
  echo "       Has the compute-alb stack been deployed?" >&2
  exit 1
fi

# --- 5. Summary before commit -------------------------------------------------
echo "Publishing DNS for env=$ENV:"
echo "  Site name:   $SITE_NAME"
echo "  Sub-zone:    $SUB_ZONE  (id=$ZONE_ID)"
echo "  ALB DNS:     $ALB_DNS"
echo "  ALB zone:    $ALB_ZONE  (regional ALB constant)"
echo ""

# --- 6. UPSERT change-batch ---------------------------------------------------
BATCH=$(mktemp)
trap 'rm -f "$BATCH"' EXIT
cat > "$BATCH" <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$SITE_NAME.",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "$ALB_DNS",
        "HostedZoneId": "$ALB_ZONE",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
EOF

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "file://$BATCH" \
  --query 'ChangeInfo.Id' --output text)

echo "✓ Route 53 change submitted (ChangeId: $CHANGE_ID)"

# --- 7. Wait for Route 53 propagation -----------------------------------------
# Past incident 2026-05-23: install-drupal-full ran smoke-test-public
# immediately after publish-dns, and the dig lookup returned no records
# because the change hadn't propagated yet. Make publish-dns self-validating:
# return only AFTER the change is INSYNC across Route 53's authoritative
# servers, then verify the local resolver can see it. Downstream callers
# (smoke-test-public, etc.) can then trust that DNS works on return.
#
# Two waits:
#   a) Route 53 INSYNC — `aws route53 wait` polls GetChange every 30s
#      until the change is consistent across all Route 53 servers.
#      Typically takes 30-60s; AWS docs say up to 5 min.
#   b) Local resolver — even after INSYNC at Route 53, the operator's
#      local resolver might have a cached NXDOMAIN. `dig` against a
#      public resolver (8.8.8.8) bypasses local cache for verification.
echo "  Waiting for Route 53 propagation (INSYNC)..."
if aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null; then
  echo "  ✓ Route 53 reports INSYNC"
else
  echo "  WARN: 'wait resource-record-sets-changed' returned non-zero." >&2
  echo "        Change may still be propagating; continuing with dig check." >&2
fi

# Verify against a public resolver (bypasses local cache). Poll for up to 60s.
echo -n "  Verifying $SITE_NAME resolves (via 8.8.8.8)"
for _ in $(seq 1 12); do
  RESOLVED=$(dig +short @8.8.8.8 "$SITE_NAME" 2>/dev/null | head -2 | tr '\n' ' ')
  if [ -n "$RESOLVED" ]; then
    echo ""
    echo "  ✓ Resolves to: $RESOLVED"
    echo ""
    echo "  End-to-end test: make smoke-test-public ENV=$ENV"
    exit 0
  fi
  echo -n "."
  sleep 5
done
echo ""
echo "  WARN: $SITE_NAME did not resolve via 8.8.8.8 within 60s." >&2
echo "        The change is submitted; propagation may need more time." >&2
echo "        Re-test with: dig +short $SITE_NAME" >&2
exit 0  # Submission succeeded; we don't want to block on slow propagation.
