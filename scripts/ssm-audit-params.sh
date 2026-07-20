#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: ssm-audit-params
# Purpose: Audit SSM Parameter Store for all expected parameters required by
#          the cf-scalable-web infrastructure. Reports missing parameters with
#          remediation guidance (which make target deploys each one).
# Parameters: --env, --region, --dry-run
# Returns: 0 if all parameters exist, 1 if any are missing
# Dependencies: aws-cli
# Created: 2026-03-03
#

set -euo pipefail

# macOS quality-of-life for AWS CLI
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# -----------------------------------------------------------------------------
# Colors for output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Function: usage
# Purpose: Display help text with usage examples
# Parameters: none
# Returns: none (prints to stdout)
# Dependencies: none
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
${BLUE}Usage:${NC}
  ssm-audit-params.sh --env <environment> [--region <region>] [--dry-run]

${YELLOW}Options:${NC}
  --env       Environment name (sandbox, staging, production)
  --region    AWS region (default: us-east-1)
  --dry-run   Show which parameters would be checked without calling AWS

${YELLOW}Examples:${NC}
  ./ssm-audit-params.sh --env sandbox
  ./ssm-audit-params.sh --env production --region us-east-1
  ./ssm-audit-params.sh --env staging --dry-run
EOF
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
ENV_NAME=""
REGION="${AWS_REGION:-us-east-1}"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; usage; exit 2 ;;
  esac
done

if [[ -z "${ENV_NAME}" ]]; then
  echo -e "${RED}ERROR: --env is required${NC}"
  usage
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo -e "${RED}ERROR: aws CLI not found${NC}"
  exit 1
fi

# -----------------------------------------------------------------------------
# Function: check_param
# Purpose: Check if an SSM parameter exists and record result
# Parameters: $1 = parameter path, $2 = category label, $3 = remediation hint
# Returns: 0 if exists, 1 if missing
# Dependencies: aws-cli
# -----------------------------------------------------------------------------
TOTAL=0
FOUND=0
MISSING=0            # only REQUIRED missing; drives exit code
MISSING_OPTIONAL=0   # missing-but-optional; informational only
MISSING_LIST=""
MISSING_OPTIONAL_LIST=""

# check_param            — REQUIRED (missing → exit 1)
# check_param_optional   — OPTIONAL (missing → WARN, exit 0)
#
# Distinction matters for partial deployments: on a fresh env where
# cf-database and cf-cache haven't been deployed yet, /rds/* and
# /cache/* params are legitimately absent. Failing the whole audit
# on those masks the real problem (missing FSx / NLB / AMIs = truly
# broken deploy). Kurt hit this 2026-04-24 — sandbox audit exited 1
# every run because RDS wasn't there yet.
check_param() {
  _check_param_impl "$1" "$2" "$3" required
}

check_param_optional() {
  _check_param_impl "$1" "$2" "$3" optional
}

_check_param_impl() {
  local param_path="$1"
  local category="$2"
  local remediation="$3"
  local kind="$4"   # required | optional
  TOTAL=$((TOTAL + 1))

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo -e "  ${CYAN}[dry-run]${NC} Would check: ${param_path} (${kind})"
    return 0
  fi

  if aws ssm get-parameter \
    --name "${param_path}" \
    --region "${REGION}" \
    --query 'Parameter.Value' \
    --output text >/dev/null 2>&1; then
    local value
    value=$(aws ssm get-parameter \
      --name "${param_path}" \
      --region "${REGION}" \
      --query 'Parameter.Value' \
      --output text 2>/dev/null)
    echo -e "  ${GREEN}OK${NC}  ${param_path}  =  ${CYAN}${value}${NC}"
    FOUND=$((FOUND + 1))
  elif [[ "${kind}" == "optional" ]]; then
    echo -e "  ${YELLOW}OPTIONAL${NC}  ${param_path}  ${YELLOW}(not deployed — OK)${NC}"
    MISSING_OPTIONAL=$((MISSING_OPTIONAL + 1))
    MISSING_OPTIONAL_LIST="${MISSING_OPTIONAL_LIST}\n  ${YELLOW}${param_path}${NC}  ->  ${YELLOW}${remediation}${NC}"
  else
    echo -e "  ${RED}MISSING${NC}  ${param_path}"
    MISSING=$((MISSING + 1))
    MISSING_LIST="${MISSING_LIST}\n  ${RED}${param_path}${NC}  ->  ${YELLOW}${remediation}${NC}"
  fi
}

# -----------------------------------------------------------------------------
# Function: section_header
# Purpose: Print a category header for grouped output
# Parameters: $1 = category name, $2 = source template
# Returns: none
# Dependencies: none
# -----------------------------------------------------------------------------
section_header() {
  local name="$1"
  local source="$2"
  echo
  echo -e "${BLUE}--- ${name} ---${NC}  ${CYAN}(source: ${source})${NC}"
}

# -----------------------------------------------------------------------------
# Audit parameters
# -----------------------------------------------------------------------------
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  SSM Parameter Store Audit${NC}"
echo -e "${BLUE}  Environment: ${CYAN}${ENV_NAME}${NC}"
echo -e "${BLUE}  Region:      ${CYAN}${REGION}${NC}"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo -e "${BLUE}  Mode:        ${YELLOW}DRY-RUN${NC}"
fi
echo -e "${BLUE}================================================================${NC}"

# --- Global Parameters ---
section_header "Global" "cf-compute-alb.yaml"
check_param "/environment/name" "Global" \
  "make deploy-compute-alb ENV=${ENV_NAME}"

# --- NLB Parameters ---
section_header "NLB" "cf-compute-nlb.yaml"
check_param "/${ENV_NAME}/nlb/endpoint" "NLB" \
  "make deploy-compute-nlb ENV=${ENV_NAME}"

# --- RDS Parameters ---
# Optional: absent during pre-database-deploy phases (fresh env,
# infra-only smoke). Present iff cf-database has been deployed.
section_header "RDS (Database) — optional" "cf-database.yaml"
check_param_optional "/${ENV_NAME}/rds/endpoint" "RDS" \
  "make deploy-database ENV=${ENV_NAME}"
check_param_optional "/${ENV_NAME}/rds/port" "RDS" \
  "make deploy-database ENV=${ENV_NAME}"
check_param_optional "/${ENV_NAME}/rds/database" "RDS" \
  "make deploy-database ENV=${ENV_NAME}"

# --- Cache Parameters ---
# Optional: absent during pre-cache-deploy phases. Present iff cf-cache
# has been deployed. Drupal degrades gracefully to DB-backed cache
# without a Valkey endpoint.
section_header "Cache (ElastiCache Valkey) — optional" "cf-cache.yaml"
check_param_optional "/${ENV_NAME}/cache/endpoint" "Cache" \
  "make deploy-cache ENV=${ENV_NAME}"
check_param_optional "/${ENV_NAME}/cache/port" "Cache" \
  "make deploy-cache ENV=${ENV_NAME}"

# --- FSx Parameters ---
section_header "FSx (Storage)" "cf-storage.yaml"
check_param "/${ENV_NAME}/fsx/dns-name" "FSx" \
  "make deploy-storage ENV=${ENV_NAME}"
check_param "/${ENV_NAME}/fsx/mount-name" "FSx" \
  "make deploy-storage ENV=${ENV_NAME}"

# --- S3 Parameters ---
section_header "S3 (Buckets)" "cf-storage.yaml"
check_param "/${ENV_NAME}/s3/media-bucket" "S3" \
  "make deploy-storage ENV=${ENV_NAME}"
check_param "/${ENV_NAME}/s3/backup-bucket" "S3" \
  "make deploy-storage ENV=${ENV_NAME}"
check_param "/${ENV_NAME}/s3/image-builder-bucket" "S3" \
  "make deploy-storage ENV=${ENV_NAME}"

# --- AMI Parameters ---
section_header "AMI (Image Builder)" "Makefile update-ami-param"
check_param "/${ENV_NAME}/ami/nginx" "AMI" \
  "make update-ami-param ENV=${ENV_NAME} PIPELINE=nginx"
check_param "/${ENV_NAME}/ami/php74" "AMI" \
  "make update-ami-param ENV=${ENV_NAME} PIPELINE=php74"
check_param "/${ENV_NAME}/ami/php83" "AMI" \
  "make update-ami-param ENV=${ENV_NAME} PIPELINE=php83"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "  Total parameters:   ${CYAN}${TOTAL}${NC}"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo -e "  ${YELLOW}Dry-run mode - no parameters were checked${NC}"
  echo
  exit 0
fi

echo -e "  Found:              ${GREEN}${FOUND}${NC}"
echo -e "  Missing (required): ${MISSING:+${RED}}${MISSING}${NC}"
echo -e "  Missing (optional): ${MISSING_OPTIONAL:+${YELLOW}}${MISSING_OPTIONAL}${NC}"
echo

if [[ "${MISSING}" -eq 0 && "${MISSING_OPTIONAL}" -eq 0 ]]; then
  echo -e "${GREEN}All expected SSM parameters are present.${NC}"
  exit 0
fi

if [[ "${MISSING_OPTIONAL}" -gt 0 ]]; then
  echo -e "${YELLOW}Optional params not present (fine — deploy the source stack when ready):${NC}"
  echo -e "${MISSING_OPTIONAL_LIST}"
  echo
fi

if [[ "${MISSING}" -eq 0 ]]; then
  echo -e "${GREEN}All required SSM parameters are present.${NC}"
  exit 0
fi

echo -e "${RED}Required params missing:${NC}"
echo -e "${MISSING_LIST}"
echo
exit 1
