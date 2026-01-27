#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: test-deployment
# Purpose: Test CloudFormation stack deployments sequentially in sandbox environment
# Parameters: action (test-vpc|test-iam|test-storage|test-database|test-cache|test-all|destroy-all)
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli, jq
# Created: 2026-01-27
#

set -eo pipefail

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="sandbox"
PARAM_FILE="cloudformation/parameters/sandbox.json"
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Stack definitions (stack_key:stack_name:template_file)
# Order matters for dependencies
STACKS=(
  "vpc:cf-scalable-web-sandbox-vpc:cloudformation/cf-vpc.yaml"
  "iam:cf-scalable-web-sandbox-iam:cloudformation/cf-iam.yaml"
  "storage:cf-scalable-web-sandbox-storage:cloudformation/cf-storage.yaml"
  "database:cf-scalable-web-sandbox-database:cloudformation/cf-database.yaml"
  "cache:cf-scalable-web-sandbox-cache:cloudformation/cf-cache.yaml"
)

# Enable strict mode after variable declarations
set -u

# -----------------------------------------------------------------------------
# Function: format_command
# Purpose: Format a command array into a shell-safe printable string
# Parameters: command arguments (varargs)
# Returns: Formatted command string
# Dependencies: printf
# -----------------------------------------------------------------------------
format_command() {
  local parts=("$@")
  local formatted=""
  local part
  for part in "${parts[@]}"; do
    formatted+=" $(printf '%q' "$part")"
  done
  echo "${formatted# }"
}

# -----------------------------------------------------------------------------
# Function: print_dry_run
# Purpose: Emit a formatted dry-run message for a command that would run
# Parameters: command arguments (varargs)
# Returns: None
# Dependencies: format_command
# -----------------------------------------------------------------------------
print_dry_run() {
  echo -e "${YELLOW}[dry-run]${NC} $(format_command "$@")"
}

# -----------------------------------------------------------------------------
# Function: run_cmd
# Purpose: Execute command or show dry-run
# Parameters: command arguments (varargs)
# Returns: Command exit code or 0 in dry-run
# Dependencies: print_dry_run
# -----------------------------------------------------------------------------
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run "$@"
    return 0
  fi
  "$@"
}

# -----------------------------------------------------------------------------
# Function: print_usage
# Purpose: Display usage information
# Parameters: None
# Returns: None
# Dependencies: None
# -----------------------------------------------------------------------------
print_usage() {
  cat << EOF
Usage: $0 [--dry-run] <action>

Options:
  --dry-run    Show what would be done without making changes

Actions:
  test-vpc       Deploy VPC stack only
  test-iam       Deploy IAM stack only
  test-storage   Deploy Storage stack only (requires VPC)
  test-database  Deploy Database stack only (requires VPC, IAM)
  test-cache     Deploy Cache stack only (requires VPC)
  test-all       Deploy all stacks in order
  destroy-all    Delete all stacks in reverse order
  status         Show status of all stacks

Environment Variables:
  AWS_REGION    AWS region (default: us-east-1)
  AWS_PROFILE   AWS CLI profile to use (optional)

Examples:
  # Test VPC deployment
  $0 test-vpc

  # Test all stacks sequentially
  $0 test-all

  # Destroy all stacks
  $0 destroy-all

  # Dry-run full deployment
  $0 --dry-run test-all

EOF
}

# -----------------------------------------------------------------------------
# Function: check_dependencies
# Purpose: Verify required tools are installed
# Parameters: None
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli, jq
# -----------------------------------------------------------------------------
check_dependencies() {
  local missing=()

  for cmd in aws jq; do
    if ! command -v "$cmd" &> /dev/null; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}" >&2
    return 1
  fi

  # Check AWS credentials (skip in dry-run)
  if [[ "$DRY_RUN" != "true" ]]; then
    if ! aws sts get-caller-identity &> /dev/null; then
      echo -e "${RED}Error: AWS credentials not configured${NC}" >&2
      echo "Run: aws configure" >&2
      return 1
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Function: get_stack_status
# Purpose: Get the current status of a CloudFormation stack
# Parameters: stack_name
# Returns: Stack status or "NOT_EXISTS"
# Dependencies: aws-cli
# -----------------------------------------------------------------------------
get_stack_status() {
  local stack_name="$1"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws cloudformation describe-stacks --stack-name "$stack_name" --region "$AWS_REGION"
    echo "UNKNOWN (dry-run)"
    return 0
  fi

  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "NOT_EXISTS")

  echo "$status"
}

# -----------------------------------------------------------------------------
# Function: wait_for_stack
# Purpose: Wait for a stack operation to complete
# Parameters: stack_name, expected_status
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli
# -----------------------------------------------------------------------------
wait_for_stack() {
  local stack_name="$1"
  local expected_status="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} Would wait for stack '$stack_name' to reach status: $expected_status"
    return 0
  fi

  echo -e "${BLUE}Waiting for stack operation to complete...${NC}"

  aws cloudformation wait "stack-${expected_status}" \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    2>/dev/null || {
      echo -e "${RED}Error: Stack operation failed or timed out${NC}" >&2
      return 1
    }

  echo -e "${GREEN}Stack operation completed${NC}"
  return 0
}

# -----------------------------------------------------------------------------
# Function: get_stack_info
# Purpose: Get stack information by key
# Parameters: stack_key (vpc|iam|storage|database|cache)
# Returns: Outputs "stack_name:template_file"
# Dependencies: None
# -----------------------------------------------------------------------------
get_stack_info() {
  local search_key="$1"
  local stack_entry

  for stack_entry in "${STACKS[@]}"; do
    local key="${stack_entry%%:*}"
    if [[ "$key" == "$search_key" ]]; then
      # Remove key prefix, return name:template
      echo "${stack_entry#*:}"
      return 0
    fi
  done

  echo -e "${RED}Error: Unknown stack key: $search_key${NC}" >&2
  return 1
}

# -----------------------------------------------------------------------------
# Function: deploy_stack
# Purpose: Deploy a single CloudFormation stack
# Parameters: stack_key (vpc|iam|storage|database|cache)
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli, run_cmd, wait_for_stack, get_stack_info
# -----------------------------------------------------------------------------
deploy_stack() {
  local stack_key="$1"
  local stack_info
  stack_info=$(get_stack_info "$stack_key") || return 1
  local stack_name="${stack_info%%:*}"
  local template_file="${stack_info##*:}"

  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}Deploying Stack: $stack_name${NC}"
  echo -e "${BLUE}Template: $template_file${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Check current status
  local current_status
  current_status=$(get_stack_status "$stack_name")
  echo -e "${BLUE}Current status: $current_status${NC}"

  # Deploy stack
  run_cmd aws cloudformation deploy \
    --template-file "$template_file" \
    --stack-name "$stack_name" \
    --parameter-overrides "file://${PARAM_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" \
    --no-fail-on-empty-changeset

  if [[ "$DRY_RUN" != "true" ]]; then
    # Get final status
    local final_status
    final_status=$(get_stack_status "$stack_name")

    if [[ "$final_status" == "CREATE_COMPLETE" ]] || [[ "$final_status" == "UPDATE_COMPLETE" ]]; then
      echo -e "${GREEN}✓ Stack deployed successfully: $stack_name${NC}"
      return 0
    else
      echo -e "${RED}✗ Stack deployment failed: $stack_name (status: $final_status)${NC}" >&2
      return 1
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Function: delete_stack
# Purpose: Delete a single CloudFormation stack
# Parameters: stack_key (vpc|iam|storage|database|cache)
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli, run_cmd, wait_for_stack, get_stack_info
# -----------------------------------------------------------------------------
delete_stack() {
  local stack_key="$1"
  local stack_info
  stack_info=$(get_stack_info "$stack_key") || return 1
  local stack_name="${stack_info%%:*}"

  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}Deleting Stack: $stack_name${NC}"
  echo -e "${BLUE}========================================${NC}"

  # Check if stack exists
  local current_status
  current_status=$(get_stack_status "$stack_name")

  if [[ "$current_status" == "NOT_EXISTS" ]]; then
    echo -e "${YELLOW}Stack does not exist: $stack_name${NC}"
    return 0
  fi

  # Delete stack
  run_cmd aws cloudformation delete-stack \
    --stack-name "$stack_name" \
    --region "$AWS_REGION"

  # Wait for deletion
  if [[ "$DRY_RUN" != "true" ]]; then
    wait_for_stack "$stack_name" "delete-complete"
    echo -e "${GREEN}✓ Stack deleted successfully: $stack_name${NC}"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Function: show_status
# Purpose: Show status of all stacks
# Parameters: None
# Returns: 0
# Dependencies: get_stack_status, get_stack_info
# -----------------------------------------------------------------------------
show_status() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}Stack Status${NC}"
  echo -e "${BLUE}========================================${NC}"

  local stack_entry
  for stack_entry in "${STACKS[@]}"; do
    local stack_key="${stack_entry%%:*}"
    local stack_info="${stack_entry#*:}"
    local stack_name="${stack_info%%:*}"
    local status
    status=$(get_stack_status "$stack_name")

    if [[ "$status" == "NOT_EXISTS" ]]; then
      echo -e "$stack_key: ${YELLOW}NOT_EXISTS${NC}"
    elif [[ "$status" == *"COMPLETE"* ]]; then
      echo -e "$stack_key: ${GREEN}$status${NC}"
    elif [[ "$status" == *"FAILED"* ]] || [[ "$status" == *"ROLLBACK"* ]]; then
      echo -e "$stack_key: ${RED}$status${NC}"
    else
      echo -e "$stack_key: ${YELLOW}$status${NC}"
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# Main script
# -----------------------------------------------------------------------------

# Parse dry-run flag
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo -e "${YELLOW}=== DRY-RUN MODE ===${NC}"
  echo -e "${YELLOW}No changes will be made to AWS${NC}"
  echo ""
  shift
fi

# Check dependencies
check_dependencies || exit 1

# Parse action
ACTION="${1:-}"

case "$ACTION" in
  test-vpc)
    deploy_stack "vpc"
    ;;

  test-iam)
    deploy_stack "iam"
    ;;

  test-storage)
    deploy_stack "storage"
    ;;

  test-database)
    deploy_stack "database"
    ;;

  test-cache)
    deploy_stack "cache"
    ;;

  test-all)
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying ALL stacks sequentially${NC}"
    echo -e "${BLUE}========================================${NC}"

    local stack_entry
    for stack_entry in "${STACKS[@]}"; do
      local stack_key="${stack_entry%%:*}"
      deploy_stack "$stack_key" || {
        echo -e "${RED}Deployment failed at: $stack_key${NC}" >&2
        exit 1
      }
      echo ""
    done

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}All stacks deployed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    ;;

  destroy-all)
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}WARNING: Destroying ALL stacks${NC}"
    echo -e "${YELLOW}========================================${NC}"

    if [[ "$DRY_RUN" != "true" ]]; then
      read -p "Are you sure? Type 'yes' to confirm: " confirm
      if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
      fi
    fi

    # Delete in reverse order
    local stack_entry
    for ((idx=${#STACKS[@]}-1; idx>=0; idx--)); do
      stack_entry="${STACKS[$idx]}"
      local stack_key="${stack_entry%%:*}"
      delete_stack "$stack_key" || {
        echo -e "${RED}Deletion failed at: $stack_key${NC}" >&2
        echo -e "${YELLOW}Continuing with remaining stacks...${NC}"
      }
      echo ""
    done

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}All stacks destroyed${NC}"
    echo -e "${GREEN}========================================${NC}"
    ;;

  status)
    show_status
    ;;

  *)
    print_usage
    exit 1
    ;;
esac

exit 0
