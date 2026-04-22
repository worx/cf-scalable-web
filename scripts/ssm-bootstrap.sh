#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: ssm-bootstrap
# Purpose: Audit and remediate SSM Agent registration across EC2 instances.
#          Reports instances missing from SSM, and optionally attaches IAM
#          instance profiles and installs the SSM Agent via SSH.
# Parameters: --profile, --region, --instance-profile, --ssh-user, --ssh-key,
#             --dry-run, report|remediate
# Returns: 0 if all instances are SSM-managed, 1 if gaps remain
# Dependencies: aws-cli, jq, ssh (for remediate)
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
  ssm-bootstrap.sh --profile <aws-profile> --region <region> --instance-profile <profile-name> [--ssh-user ubuntu] [--ssh-key ~/.ssh/id_rsa] [--dry-run] <report|remediate>

${YELLOW}Options:${NC}
  --profile           AWS CLI profile name
  --region            AWS region (e.g. us-east-1)
  --instance-profile  IAM instance profile name to attach
  --ssh-user          SSH username (default: ubuntu)
  --ssh-key           Path to SSH private key (required for remediate)
  --dry-run           Show what would be done without executing

${YELLOW}Actions:${NC}
  report              Show instances missing from SSM
  remediate           Attach IAM profile + install SSM Agent via SSH

${YELLOW}Examples:${NC}
  ./ssm-bootstrap.sh --profile prod --region us-east-1 --instance-profile wx-ec2-ssm-profile report
  ./ssm-bootstrap.sh --profile prod --region us-east-1 --instance-profile wx-ec2-ssm-profile --ssh-user ubuntu --ssh-key ~/.ssh/worx.pem remediate
EOF
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
PROFILE=""
REGION=""
INSTANCE_PROFILE_NAME=""
SSH_USER="ubuntu"
SSH_KEY=""
DRY_RUN="0"
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --instance-profile) INSTANCE_PROFILE_NAME="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift 1 ;;
    report|remediate) ACTION="$1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; usage; exit 2 ;;
  esac
done

if [[ -z "${ACTION}" || -z "${PROFILE}" || -z "${REGION}" || -z "${INSTANCE_PROFILE_NAME}" ]]; then
  usage
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo -e "${RED}ERROR: aws CLI not found${NC}"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq not found${NC}"
  exit 1
fi

if [[ "${ACTION}" == "remediate" && -z "${SSH_KEY}" ]]; then
  echo -e "${RED}ERROR: --ssh-key is required for remediate${NC}"
  exit 2
fi

# -----------------------------------------------------------------------------
# Temporary files
# -----------------------------------------------------------------------------
TMPDIR="$(mktemp -d)"
EC2_JSON="${TMPDIR}/ec2.json"
SSM_JSON="${TMPDIR}/ssm.json"
EC2_FLAT="${TMPDIR}/ec2.flat.json"
SSM_IDS="${TMPDIR}/ssm.ids.txt"
GAP_JSON="${TMPDIR}/gap.json"

# -----------------------------------------------------------------------------
# Function: cleanup
# Purpose: Remove temporary directory on exit
# Parameters: none
# Returns: none
# Dependencies: none
# -----------------------------------------------------------------------------
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Function: aws_cmd
# Purpose: Execute an AWS CLI command, or print it in dry-run mode
# Parameters: AWS CLI arguments (varargs)
# Returns: 0 on success (or dry-run), AWS CLI exit code otherwise
# Dependencies: aws-cli
# -----------------------------------------------------------------------------
aws_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo -e "${CYAN}[dry-run]${NC} aws $*"
    return 0
  fi
  aws --profile "${PROFILE}" --region "${REGION}" "$@"
}

# -----------------------------------------------------------------------------
# Gather data
# -----------------------------------------------------------------------------
echo -e "${BLUE}==> Fetching EC2 running instances...${NC}"
aws --profile "${PROFILE}" --region "${REGION}" ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  > "${EC2_JSON}"

echo -e "${BLUE}==> Fetching SSM managed instances...${NC}"
aws --profile "${PROFILE}" --region "${REGION}" ssm describe-instance-information \
  > "${SSM_JSON}"

# Flatten EC2 instances into a compact array of objects
jq -c '
  [
    .Reservations[].Instances[] |
    {
      InstanceId,
      Name: ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // ""),
      PublicIp: (.PublicIpAddress // ""),
      PrivateIp: (.PrivateIpAddress // ""),
      Platform: (.PlatformDetails // ""),
      IamInstanceProfileArn: (.IamInstanceProfile.Arn // "")
    }
  ]
' "${EC2_JSON}" > "${EC2_FLAT}"

jq -r '.InstanceInformationList[].InstanceId' "${SSM_JSON}" | sort -u > "${SSM_IDS}"

# Build gap list: EC2 running but not in SSM
jq -c --slurpfile ssm_ids <(jq -R -s -c 'split("\n")|map(select(length>0))' "${SSM_IDS}") '
  map(select(.InstanceId as $id | ($ssm_ids[0] | index($id)) | not))
' "${EC2_FLAT}" > "${GAP_JSON}"

EC2_COUNT="$(jq 'length' "${EC2_FLAT}")"
SSM_COUNT="$(jq '.InstanceInformationList | length' "${SSM_JSON}")"
GAP_COUNT="$(jq 'length' "${GAP_JSON}")"

echo
echo -e "${BLUE}==== Summary ====${NC}"
echo -e "EC2 running:      ${CYAN}${EC2_COUNT}${NC}"
echo -e "SSM managed:      ${CYAN}${SSM_COUNT}${NC}"
if [[ "${GAP_COUNT}" -eq 0 ]]; then
  echo -e "Missing from SSM: ${GREEN}0${NC}"
else
  echo -e "Missing from SSM: ${RED}${GAP_COUNT}${NC}"
fi
echo

if [[ "${GAP_COUNT}" -eq 0 ]]; then
  echo -e "${GREEN}All running instances appear to be SSM-managed. Done.${NC}"
  exit 0
fi

echo -e "${YELLOW}==== Missing from SSM (Name, InstanceId, PublicIp, PrivateIp, HasProfile) ====${NC}"
jq -r '
  .[] |
  "\(.Name)\t\(.InstanceId)\t\(.PublicIp)\t\(.PrivateIp)\t\((.IamInstanceProfileArn|length)>0)"
' "${GAP_JSON}" | column -t -s $'\t'

if [[ "${ACTION}" == "report" ]]; then
  echo
  echo -e "${CYAN}Tip: run remediate to attach IAM profile + install agent via SSH.${NC}"
  exit 0
fi

echo
echo -e "${BLUE}==> Remediating ${GAP_COUNT} instances...${NC}"

# 1) Attach IAM instance profile where missing
echo -e "${BLUE}==> Step 1: Ensure IAM instance profile attached...${NC}"
jq -r '
  .[] |
  select((.IamInstanceProfileArn|length)==0) |
  .InstanceId
' "${GAP_JSON}" | while read -r IID; do
  [[ -z "${IID}" ]] && continue
  echo -e "Attaching instance profile '${INSTANCE_PROFILE_NAME}' to ${CYAN}${IID}${NC} ..."
  aws_cmd ec2 associate-iam-instance-profile \
    --iam-instance-profile Name="${INSTANCE_PROFILE_NAME}" \
    --instance-id "${IID}" >/dev/null || true
done

echo -e "${YELLOW}==> Waiting a moment for IAM profile propagation...${NC}"
sleep 8

# 2) Install/start SSM agent via SSH
# Supports Ubuntu (snap/apt) and Amazon Linux 2 (yum)
install_cmd='
set -e
sudo -n true 2>/dev/null || true

if command -v amazon-ssm-agent >/dev/null 2>&1; then
  echo "amazon-ssm-agent already installed"
else
  # Amazon Linux 2 / RHEL / CentOS (yum-based)
  if command -v yum >/dev/null 2>&1; then
    echo "Installing via yum..."
    sudo yum install -y amazon-ssm-agent || true
  # Ubuntu / Debian (snap or apt)
  elif command -v snap >/dev/null 2>&1; then
    echo "Installing via snap..."
    sudo snap install amazon-ssm-agent --classic || true
  fi

  if ! command -v amazon-ssm-agent >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    echo "Installing via apt..."
    sudo apt-get update -y
    sudo apt-get install -y amazon-ssm-agent || true
  fi
fi

# Enable + start (service name differs sometimes)
if systemctl list-unit-files | grep -q amazon-ssm-agent; then
  sudo systemctl enable amazon-ssm-agent
  sudo systemctl restart amazon-ssm-agent
elif service --status-all 2>&1 | grep -q amazon-ssm-agent; then
  sudo service amazon-ssm-agent restart || true
fi

# Quick status
if systemctl status amazon-ssm-agent >/dev/null 2>&1; then
  systemctl is-active amazon-ssm-agent || true
fi
echo "done"
'

echo
echo -e "${BLUE}==> Step 2: Install/start amazon-ssm-agent via SSH...${NC}"

jq -r '
  .[] |
  "\(.InstanceId)\t\(.Name)\t\(.PublicIp)\t\(.PrivateIp)"
' "${GAP_JSON}" | while IFS=$'\t' read -r IID NAME PUB PRIV; do
  TARGET=""
  if [[ -n "${PUB}" ]]; then
    TARGET="${PUB}"
  else
    # If no public IP, use private IP (assumes you're on VPN/deploy host/etc.)
    TARGET="${PRIV}"
  fi

  if [[ -z "${TARGET}" ]]; then
    echo -e "${YELLOW}Skipping ${IID} (${NAME}) - no IP found${NC}"
    continue
  fi

  echo -e "${CYAN}--- ${IID} ${NAME} @ ${TARGET} ---${NC}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo -e "${CYAN}[dry-run]${NC} ssh -i ${SSH_KEY} ${SSH_USER}@${TARGET} <install_cmd>"
    continue
  fi

  ssh -o StrictHostKeyChecking=accept-new -i "${SSH_KEY}" "${SSH_USER}@${TARGET}" "${install_cmd}" || {
    echo -e "${RED}WARN: SSH install failed for ${IID} (${NAME}) @ ${TARGET}${NC}"
  }
done

# 3) Verify: re-poll SSM and show remaining gaps
echo
echo -e "${BLUE}==> Step 3: Verify SSM registration...${NC}"
sleep 10
aws --profile "${PROFILE}" --region "${REGION}" ssm describe-instance-information > "${SSM_JSON}"
jq -r '.InstanceInformationList[].InstanceId' "${SSM_JSON}" | sort -u > "${SSM_IDS}"

jq -c --slurpfile ssm_ids <(jq -R -s -c 'split("\n")|map(select(length>0))' "${SSM_IDS}") '
  map(select(.InstanceId as $id | ($ssm_ids[0] | index($id)) | not))
' "${EC2_FLAT}" > "${GAP_JSON}"

REMAINING="$(jq 'length' "${GAP_JSON}")"
echo -e "Remaining missing from SSM: ${REMAINING}"

if [[ "${REMAINING}" -gt 0 ]]; then
  echo
  echo -e "${RED}Still missing (likely networking egress/endpoint issues, or agent install failed):${NC}"
  jq -r '.[] | "\(.Name)\t\(.InstanceId)\t\(.PublicIp)\t\(.PrivateIp)"' "${GAP_JSON}" | column -t -s $'\t'
  exit 1
fi

echo -e "${GREEN}All running instances are now SSM-managed.${NC}"
