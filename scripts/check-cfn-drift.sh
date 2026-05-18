#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# check-cfn-drift: Compare local CloudFormation templates to deployed stacks
# and flag those whose last-committed source is newer than the deployed
# version (i.e., changes are sitting in git but never made it to AWS).
#
# Usage: scripts/check-cfn-drift.sh <env>
#
# Output: one line per template, status one of:
#   OK            local committed time <= deployed LastUpdatedTime
#   DRIFT         local newer than deployed (changes pending deploy)
#   UNCOMMITTED   local working tree differs from git (commit first)
#   NEW           template exists in git, no matching stack in AWS yet
#   ?             aws cli or git query failed; investigate
#
# Exit codes:
#   0   nothing pending (every deployed stack is in sync)
#   1   at least one DRIFT or UNCOMMITTED
#   2   misuse (missing env arg, etc.)
#
# Limitations (for future iteration):
#   - Only checks templates, not parameter files. RecipeVersion bumps in
#     cloudformation/parameters/*.json won't show as drift until a
#     downstream template re-uses the param.
#   - Uses git's last-commit timestamp for the template. A reverted-then-
#     re-applied edit might confuse the comparison; use git history.

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

# Stack-name resolver (mirrors the *_STACK variables at the top of the Makefile).
# A function instead of an associative array so this runs on macOS bash 3.2
# as well as the deploy-host's bash 4+. Returns empty for unknown bases.
STACK_PREFIX="cf-scalable-web-${ENV}"
stack_for() {
  case "$1" in
    vpc|iam|storage|database|cache|app-drupal|image-builder|\
    compute-alb|compute-nlb|compute-nginx|compute-php|deploy-peering)
      echo "${STACK_PREFIX}-$1" ;;
    deploy-host)
      # No env prefix — deploy-host is shared infrastructure
      echo "cf-deploy-host" ;;
    *)
      echo "" ;;
  esac
}

# Color (skip when not on a TTY to stay log-friendly)
if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; NC=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

# Convert an AWS ISO-8601 timestamp ("2026-05-15T20:03:09.343000+00:00") to
# Unix epoch. Try GNU date first (Linux), fall back to BSD (macOS).
iso_to_epoch() {
  local iso="$1"
  local clean="${iso%.*}"   # strip fractional seconds + timezone marker
  date -d "$iso" +%s 2>/dev/null || \
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "${clean%+*}" +%s 2>/dev/null || \
    echo "0"
}

epoch_to_human() {
  date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || \
    date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || \
    echo "?"
}

printf "${CYAN}%-32s %-12s %-18s %-18s${NC}\n" "TEMPLATE" "STATUS" "COMMITTED" "DEPLOYED"
printf "${CYAN}%-32s %-12s %-18s %-18s${NC}\n" "--------" "------" "---------" "--------"

drift_count=0
uncommitted_count=0
new_count=0
checked_count=0

for base in vpc iam storage database cache app-drupal image-builder \
            compute-alb compute-nlb compute-nginx compute-php \
            deploy-peering deploy-host; do
  template="cloudformation/cf-${base}.yaml"
  stack=$(stack_for "$base")
  checked_count=$((checked_count + 1))

  if [ ! -f "$template" ]; then
    printf "%-32s ${YELLOW}%-12s${NC} %s\n" "cf-${base}.yaml" "MISSING" "(template not in repo)"
    continue
  fi

  # Working-tree dirtiness check
  if ! git diff --quiet -- "$template" 2>/dev/null; then
    printf "%-32s ${YELLOW}%-12s${NC} %-18s %-18s\n" \
      "cf-${base}.yaml" "UNCOMMITTED" "(working tree)" ""
    uncommitted_count=$((uncommitted_count + 1))
    continue
  fi

  # Git last-commit timestamp for the template
  file_epoch=$(git log -1 --format=%ct -- "$template" 2>/dev/null || echo "0")
  file_human=$(epoch_to_human "$file_epoch")

  # Stack LastUpdatedTime (falls back to CreationTime via the JMESPath
  # `||` operator if the stack has never been updated)
  stack_time=$(aws cloudformation describe-stacks --stack-name "$stack" \
    --query 'Stacks[0].LastUpdatedTime || Stacks[0].CreationTime' \
    --output text 2>/dev/null || true)

  if [ -z "$stack_time" ] || [ "$stack_time" = "None" ]; then
    printf "%-32s ${CYAN}%-12s${NC} %-18s %-18s\n" \
      "cf-${base}.yaml" "NEW" "$file_human" "(not deployed)"
    new_count=$((new_count + 1))
    continue
  fi

  stack_epoch=$(iso_to_epoch "$stack_time")
  stack_human=$(epoch_to_human "$stack_epoch")

  if [ "$file_epoch" -gt "$stack_epoch" ]; then
    printf "%-32s ${RED}%-12s${NC} %-18s %-18s\n" \
      "cf-${base}.yaml" "DRIFT" "$file_human" "$stack_human"
    drift_count=$((drift_count + 1))
  else
    printf "%-32s ${GREEN}%-12s${NC} %-18s %-18s\n" \
      "cf-${base}.yaml" "OK" "$file_human" "$stack_human"
  fi
done

echo ""
printf "Checked: %d  ${GREEN}OK${NC}: %d  ${RED}DRIFT${NC}: %d  ${YELLOW}UNCOMMITTED${NC}: %d  ${CYAN}NEW${NC}: %d\n" \
  "$checked_count" \
  "$((checked_count - drift_count - uncommitted_count - new_count))" \
  "$drift_count" "$uncommitted_count" "$new_count"

if [ "$drift_count" -gt 0 ] || [ "$uncommitted_count" -gt 0 ]; then
  echo ""
  if [ "$drift_count" -gt 0 ]; then
    echo "${RED}→ Run \`make deploy-<stack> ENV=$ENV\` for each DRIFT template.${NC}"
  fi
  if [ "$uncommitted_count" -gt 0 ]; then
    echo "${YELLOW}→ Commit local changes first, then deploy.${NC}"
  fi
  exit 1
fi
exit 0
