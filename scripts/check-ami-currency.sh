#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# check-ami-currency: are the AMIs currently referenced in SSM
# (for ENV's nginx + php74 + php83 pipelines) built from the SAME
# recipe version that's in image-builder-<env>.json's RecipeVersion?
#
# Each AMI carries an `Ec2ImageBuilderArn` tag whose ARN looks like:
#   arn:aws:imagebuilder:REGION:ACCT:image/<recipe-name>/<version>/<build>
# We parse the <version> segment and compare to the configured
# RecipeVersion in the env's parameter file.
#
# Exit codes:
#   0 = all 3 AMIs are current (no rebuild needed)
#   1 = at least one AMI needs rebuilding (or doesn't exist yet)
#   2 = usage error
#
# Used by `make build-amis-if-needed` to skip the ~25-min AMI bake
# on incremental deploys where nothing in the recipes changed.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

PARAMS_FILE="cloudformation/parameters/image-builder-${ENV}.json"
if [ ! -f "$PARAMS_FILE" ]; then
  echo "ERROR: parameter file not found: $PARAMS_FILE" >&2
  exit 2
fi

TARGET_VERSION=$(jq -r '.Parameters.RecipeVersion' "$PARAMS_FILE")
if [ -z "$TARGET_VERSION" ] || [ "$TARGET_VERSION" = "null" ]; then
  echo "ERROR: RecipeVersion not found in $PARAMS_FILE" >&2
  exit 2
fi

echo "Target recipe version (from $PARAMS_FILE): $TARGET_VERSION"
echo ""

NEED_BUILD=0
printf "  %-8s  %-22s  %-10s  %s\n" "PIPELINE" "CURRENT AMI" "VERSION" "STATUS"
printf "  %-8s  %-22s  %-10s  %s\n" "--------" "----------------------" "----------" "------"

for PIPELINE in nginx php74 php83; do
  AMI_ID=$(aws ssm get-parameter \
    --name "/$ENV/ami/$PIPELINE" \
    --query 'Parameter.Value' --output text 2>/dev/null) || AMI_ID=""

  if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    printf "  %-8s  %-22s  %-10s  %s\n" "$PIPELINE" "(no SSM param)" "-" "NEEDS BUILD"
    NEED_BUILD=1
    continue
  fi

  # Get the Ec2ImageBuilderArn tag from the AMI
  AMI_TAG=$(aws ec2 describe-images --image-ids "$AMI_ID" \
    --query "Images[0].Tags[?Key=='Ec2ImageBuilderArn'].Value | [0]" \
    --output text 2>/dev/null) || AMI_TAG=""

  if [ -z "$AMI_TAG" ] || [ "$AMI_TAG" = "None" ]; then
    # AMI exists but isn't Image-Builder-tagged (manual import, etc.).
    # Treat as needing rebuild — we can't verify currency.
    printf "  %-8s  %-22s  %-10s  %s\n" "$PIPELINE" "$AMI_ID" "(untagged)" "NEEDS BUILD"
    NEED_BUILD=1
    continue
  fi

  # Parse <version> from the ARN: positions are .../image/<name>/<version>/<build>
  AMI_VERSION=$(echo "$AMI_TAG" | awk -F/ '{print $(NF-1)}')

  if [ "$AMI_VERSION" = "$TARGET_VERSION" ]; then
    printf "  %-8s  %-22s  %-10s  %s\n" "$PIPELINE" "$AMI_ID" "$AMI_VERSION" "✓ current"
  else
    printf "  %-8s  %-22s  %-10s  %s\n" "$PIPELINE" "$AMI_ID" "$AMI_VERSION" "stale (need $TARGET_VERSION)"
    NEED_BUILD=1
  fi
done

echo ""
if [ "$NEED_BUILD" = "0" ]; then
  echo "✓ All AMIs are at recipe version $TARGET_VERSION — no rebuild needed."
  exit 0
else
  echo "✗ At least one AMI is stale or missing — rebuild required."
  exit 1
fi
