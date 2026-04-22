#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: manage-secrets
# Purpose: Manage AWS Secrets Manager secrets for cf-scalable-web infrastructure
# Parameters: action, secret-name, value (optional), prefix (optional)
# Returns: 0 on success, 1 on error
# Dependencies: aws-cli, jq
# Created: 2026-01-26
# Updated: 2026-01-26 - Enhanced dry-run implementation
#

set -euo pipefail

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
DEFAULT_PREFIX="worxco/production"
DRY_RUN=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
# Returns: Formatted dry-run output
# Dependencies: format_command
# -----------------------------------------------------------------------------
print_dry_run() {
  echo -e "${YELLOW}[dry-run]${NC} $(format_command "$@")"
}

# -----------------------------------------------------------------------------
# Function: run_cmd
# Purpose: Execute a command unless dry-run mode is enabled
# Parameters: command arguments (varargs)
# Returns: Command exit code (or 0 in dry-run mode)
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
# Function: run_cmd_capture
# Purpose: Execute a command and capture its stdout into a variable, honoring dry-run
# Parameters: variable_name, command arguments (varargs)
# Returns: Command exit code (or 0 in dry-run mode)
# Dependencies: print_dry_run
# -----------------------------------------------------------------------------
run_cmd_capture() {
  local __var="$1"
  shift

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run "$@"
    printf -v "$__var" '%s' ""
    return 0
  fi

  local __output
  __output="$("$@")"
  printf -v "$__var" '%s' "$__output"
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
Usage: $0 [--dry-run] <action> [arguments]

Options:
  --dry-run    Show what would be done without making changes

Actions:
  add-ssh-key <name> <public-key-file> [prefix]
      Add an SSH public key to Secrets Manager
      Example: $0 add-ssh-key kurt ~/.ssh/id_rsa.pub worxco/prod
      Example (dry-run): $0 --dry-run add-ssh-key kurt ~/.ssh/id_rsa.pub worxco/prod

  add-secret <secret-name> <value> [prefix]
      Add a generic secret
      Example: $0 add-secret root-password "MySecurePassword" worxco/prod

  get <secret-name> [prefix]
      Retrieve a secret value
      Example: $0 get ssh-keys/kurt worxco/prod

  list [prefix]
      List all secrets with given prefix
      Example: $0 list worxco/prod

  delete <secret-name> [prefix]
      Delete a secret (requires confirmation, skipped in dry-run)
      Example: $0 delete ssh-keys/kurt worxco/prod

  init <prefix>
      Initialize all required secrets for deployment
      Example: $0 init worxco/prod

Environment Variables:
  AWS_REGION    AWS region (default: us-east-1)
  AWS_PROFILE   AWS CLI profile to use (optional)
  DRY_RUN       Set to "true" to enable dry-run mode (optional)

EOF
}

# -----------------------------------------------------------------------------
# Function: check_dependencies
# Purpose: Verify required tools are installed and AWS credentials configured
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
    echo "Please install: ${missing[*]}" >&2
    return 1
  fi

  # Check AWS credentials (skip in dry-run for offline testing)
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
# Function: add_ssh_key
# Purpose: Add SSH public key to Secrets Manager
# Parameters: name, public_key_file, prefix
# Returns: 0 on success, 1 on error
# Dependencies: run_cmd, AWS CLI, Secrets Manager
# -----------------------------------------------------------------------------
add_ssh_key() {
  local name="$1"
  local key_file="$2"
  local prefix="${3:-$DEFAULT_PREFIX}"
  local secret_name="${prefix}/ssh-keys/${name}"

  if [ ! -f "$key_file" ]; then
    echo -e "${RED}Error: Key file not found: $key_file${NC}" >&2
    return 1
  fi

  local key_content
  key_content=$(cat "$key_file")

  echo -e "${BLUE}Adding SSH key: $secret_name${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION"
    echo -e "${YELLOW}[dry-run]${NC} Would check if secret exists, then either update or create:"
    echo -e "${YELLOW}[dry-run]${NC}   If exists:"
    print_dry_run aws secretsmanager put-secret-value \
      --secret-id "$secret_name" \
      --secret-string "[${#key_content} characters]" \
      --region "$AWS_REGION"
    echo -e "${YELLOW}[dry-run]${NC}   If not exists:"
    print_dry_run aws secretsmanager create-secret \
      --name "$secret_name" \
      --description "SSH public key for $name" \
      --secret-string "[${#key_content} characters]" \
      --region "$AWS_REGION"
    return 0
  fi

  if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION" &> /dev/null; then
    echo -e "${YELLOW}Secret already exists. Updating...${NC}"
    run_cmd aws secretsmanager put-secret-value \
      --secret-id "$secret_name" \
      --secret-string "$key_content" \
      --region "$AWS_REGION" \
      --output json | jq -r '.ARN'
  else
    run_cmd aws secretsmanager create-secret \
      --name "$secret_name" \
      --description "SSH public key for $name" \
      --secret-string "$key_content" \
      --region "$AWS_REGION" \
      --output json | jq -r '.ARN'
  fi

  echo -e "${GREEN}✓ SSH key added successfully${NC}"
}

# -----------------------------------------------------------------------------
# Function: add_secret
# Purpose: Add a generic secret to Secrets Manager
# Parameters: secret_name, value, prefix
# Returns: 0 on success, 1 on error
# Dependencies: run_cmd, AWS CLI, Secrets Manager
# -----------------------------------------------------------------------------
add_secret() {
  local name="$1"
  local value="$2"
  local prefix="${3:-$DEFAULT_PREFIX}"
  local secret_name="${prefix}/${name}"

  echo -e "${BLUE}Adding secret: $secret_name${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION"
    echo -e "${YELLOW}[dry-run]${NC} Would check if secret exists, then either update or create:"
    echo -e "${YELLOW}[dry-run]${NC}   Value length: ${#value} characters"
    print_dry_run aws secretsmanager put-secret-value \
      --secret-id "$secret_name" \
      --secret-string "[REDACTED]" \
      --region "$AWS_REGION"
    return 0
  fi

  if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION" &> /dev/null; then
    echo -e "${YELLOW}Secret already exists. Updating...${NC}"
    run_cmd aws secretsmanager put-secret-value \
      --secret-id "$secret_name" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output json | jq -r '.ARN'
  else
    run_cmd aws secretsmanager create-secret \
      --name "$secret_name" \
      --description "Secret: $name" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output json | jq -r '.ARN'
  fi

  echo -e "${GREEN}✓ Secret added successfully${NC}"
}

# -----------------------------------------------------------------------------
# Function: get_secret
# Purpose: Retrieve a secret value from Secrets Manager
# Parameters: secret_name, prefix
# Returns: 0 on success, 1 on error
# Dependencies: run_cmd, AWS CLI, Secrets Manager
# -----------------------------------------------------------------------------
get_secret() {
  local name="$1"
  local prefix="${2:-$DEFAULT_PREFIX}"
  local secret_name="${prefix}/${name}"

  echo -e "${BLUE}Retrieving secret: $secret_name${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws secretsmanager get-secret-value \
      --secret-id "$secret_name" \
      --region "$AWS_REGION" \
      --query SecretString \
      --output text
    echo -e "${YELLOW}[dry-run]${NC} (In a real run, the secret value would be displayed here)"
    return 0
  fi

  run_cmd aws secretsmanager get-secret-value \
    --secret-id "$secret_name" \
    --region "$AWS_REGION" \
    --output json | jq -r '.SecretString'
}

# -----------------------------------------------------------------------------
# Function: list_secrets
# Purpose: List all secrets with a given prefix
# Parameters: prefix
# Returns: 0 on success
# Dependencies: AWS CLI, Secrets Manager
# -----------------------------------------------------------------------------
list_secrets() {
  local prefix="${1:-$DEFAULT_PREFIX}"

  echo -e "${BLUE}Secrets with prefix: $prefix${NC}\n"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws secretsmanager list-secrets --region "$AWS_REGION"
    echo -e "${YELLOW}[dry-run]${NC} (Would filter by prefix '$prefix' and display in table format)"
    return 0
  fi

  run_cmd aws secretsmanager list-secrets \
    --region "$AWS_REGION" \
    --output json | \
    jq -r --arg prefix "$prefix" \
      '.SecretList[] | select(.Name | startswith($prefix)) |
       "\(.Name)\t\(.Description // "No description")\t\(.LastChangedDate)"' | \
    column -t -s $'\t'
}

# -----------------------------------------------------------------------------
# Function: delete_secret
# Purpose: Delete a secret from Secrets Manager
# Parameters: secret_name, prefix
# Returns: 0 on success, 1 on error
# Dependencies: run_cmd, AWS CLI, Secrets Manager
# -----------------------------------------------------------------------------
delete_secret() {
  local name="$1"
  local prefix="${2:-$DEFAULT_PREFIX}"
  local secret_name="${prefix}/${name}"

  echo -e "${YELLOW}WARNING: This will delete secret: $secret_name${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_dry_run aws secretsmanager delete-secret \
      --secret-id "$secret_name" \
      --recovery-window-in-days 7 \
      --region "$AWS_REGION"
    echo -e "${YELLOW}[dry-run]${NC} (In a real run, would prompt for 'yes' confirmation before deletion)"
    return 0
  fi

  read -rp "Are you sure? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Cancelled"
    return 0
  fi

  run_cmd aws secretsmanager delete-secret \
    --secret-id "$secret_name" \
    --recovery-window-in-days 7 \
    --region "$AWS_REGION"

  echo -e "${GREEN}✓ Secret scheduled for deletion (7-day recovery window)${NC}"
}

# -----------------------------------------------------------------------------
# Function: init_secrets
# Purpose: Initialize all required secrets for deployment
# Parameters: prefix
# Returns: 0 on success
# Dependencies: add_secret, add_ssh_key
# -----------------------------------------------------------------------------
init_secrets() {
  local prefix="${1:-$DEFAULT_PREFIX}"

  echo -e "${BLUE}Initializing secrets for prefix: $prefix${NC}\n"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} Would interactively prompt for:"
    echo -e "${YELLOW}[dry-run]${NC}   - Root password"
    echo -e "${YELLOW}[dry-run]${NC}   - Notification email"
    echo -e "${YELLOW}[dry-run]${NC}   - SSH keys (multiple)"
    echo -e "${YELLOW}[dry-run]${NC} Then would create secrets using add_secret and add_ssh_key functions"
    return 0
  fi

  # Root password
  echo -e "${YELLOW}Setting root password...${NC}"
  read -rsp "Enter root password for instances: " root_pass
  echo
  add_secret "root-password" "$root_pass" "$prefix"

  # Notification email
  echo -e "\n${YELLOW}Setting notification email...${NC}"
  read -rp "Enter email for CloudWatch alarms: " email
  add_secret "notifications/email" "$email" "$prefix"

  # SSH keys
  echo -e "\n${YELLOW}Adding SSH keys...${NC}"
  echo "Enter paths to SSH public keys (press Enter with empty path to finish):"

  local key_count=0
  while true; do
    read -rp "SSH key path (or Enter to skip): " key_path
    [ -z "$key_path" ] && break

    if [ -f "$key_path" ]; then
      read -rp "Name for this key (e.g., kurt): " key_name
      add_ssh_key "$key_name" "$key_path" "$prefix"
      ((key_count++))
    else
      echo -e "${RED}File not found: $key_path${NC}"
    fi
  done

  echo -e "\n${GREEN}✓ Initialization complete${NC}"
  echo -e "  - Root password: ${prefix}/root-password"
  echo -e "  - Notification email: ${prefix}/notifications/email"
  echo -e "  - SSH keys added: $key_count"
  echo -e "\n${BLUE}Note: RDS and cache secrets will be auto-generated by CloudFormation${NC}"
}

# -----------------------------------------------------------------------------
# Main script
# -----------------------------------------------------------------------------
main() {
  # Parse --dry-run flag
  if [ "$1" = "--dry-run" ] 2>/dev/null; then
    DRY_RUN=true
    shift
  fi

  if [ $# -lt 1 ]; then
    print_usage
    exit 1
  fi

  check_dependencies || exit 1

  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}=== DRY-RUN MODE ===${NC}"
    echo -e "${YELLOW}No changes will be made to AWS${NC}\n"
  fi

  local action="$1"
  shift

  case "$action" in
    add-ssh-key)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error: add-ssh-key requires name and key file${NC}" >&2
        print_usage
        exit 1
      fi
      add_ssh_key "$@"
      ;;
    add-secret)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error: add-secret requires name and value${NC}" >&2
        print_usage
        exit 1
      fi
      add_secret "$@"
      ;;
    get)
      if [ $# -lt 1 ]; then
        echo -e "${RED}Error: get requires secret name${NC}" >&2
        print_usage
        exit 1
      fi
      get_secret "$@"
      ;;
    list)
      list_secrets "$@"
      ;;
    delete)
      if [ $# -lt 1 ]; then
        echo -e "${RED}Error: delete requires secret name${NC}" >&2
        print_usage
        exit 1
      fi
      delete_secret "$@"
      ;;
    init)
      init_secrets "$@"
      ;;
    *)
      echo -e "${RED}Error: Unknown action: $action${NC}" >&2
      print_usage
      exit 1
      ;;
  esac
}

main "$@"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
