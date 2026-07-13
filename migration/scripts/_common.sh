#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/migration/_common.sh
#
# Purpose:  Shared shell helpers for the migration script fleet — both
#           the jumpbox-side (prod account) and deploy-host-side
#           (sandbox account) scripts source this to get consistent
#           idempotency, logging, and confirmation behavior.
#
# Usage:    Source, do NOT execute. From a script one level deep
#           (jumpbox/foo.sh or deploy-host/foo.sh):
#
#             source "$(dirname "$0")/../_common.sh"
#
# Provides:
#   Environment flags honored:
#     CONFIRMED=yes    Skip interactive confirmation prompts
#     DRY_RUN=yes      Print commands instead of executing them
#
#   Functions:
#     confirm_or_exit "message"       Interactive Y/N; honors CONFIRMED=yes
#     is_dry_run                       Boolean check for DRY_RUN=yes
#     run_or_echo cmd args...          Execute or preview a single command
#     log_init "script-name"           Set up tee-based file logging
#     log_upload_and_exit "s3-bucket"  Ship log to S3 on exit (use with trap)
#     require_env VAR1 VAR2 ...        Fail loud if any env vars are unset
#     log_info / log_warn / log_error / log_ok / log_step
#                                       Colored structured log lines
#     mask_secret "value"              Return "ab***yz" for logging
#
#   ANSI color codes exported:
#     RED CYAN YELLOW GREEN BLUE NC
#     (matches the Makefile's $(RED), $(CYAN), etc. — visual consistency)
#
# Note: This file does NOT `set -euo pipefail`. The sourcing script
#       should set its own shell options — imposing them here would
#       change behavior in ways the caller might not expect.
#
# Created: 2026-07-10
#

# ============================================================
# Guard against double-sourcing
# ============================================================
if [ -n "${_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
_COMMON_SH_LOADED=1

# ============================================================
# ANSI color codes — mirror the Makefile's $(RED), $(CYAN), etc.
# ============================================================
export RED='\033[0;31m'
export CYAN='\033[0;36m'
export YELLOW='\033[1;33m'
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export NC='\033[0m'   # No Color / reset

# ============================================================
# Function: confirm_or_exit
# Purpose:  Interactive Y/N confirmation prompt (skipped when
#           CONFIRMED=yes is set — mirrors Makefile convention).
# Parameters:
#   $1 - Warning message to display (optional; defaults to generic).
# Returns:
#   0 on confirmation (either CONFIRMED=yes or user typed 'yes').
#   Calls `exit 0` on any other input (matches Makefile behavior:
#   cancellation is not a failure, just a no-op).
# Dependencies: bash, read
# Created: 2026-07-10
# ============================================================
confirm_or_exit() {
  local msg="${1:-This will perform a destructive action.}"
  if [ "${CONFIRMED:-}" = "yes" ]; then
    return 0
  fi
  printf '%bWARNING: %s%b\n' "$RED" "$msg" "$NC" >&2
  printf '%b(Set CONFIRMED=yes to skip this prompt for unattended runs.)%b\n' \
    "$CYAN" "$NC" >&2
  local confirm=""
  read -r -p "Type 'yes' to confirm: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Cancelled" >&2
    exit 0
  fi
}

# ============================================================
# Function: is_dry_run
# Purpose:  Boolean check for DRY_RUN=yes; enables if-block guarding
#           for pipelines and multi-line constructs that can't be
#           passed as arguments to run_or_echo.
# Parameters: none
# Returns:  0 (true) if DRY_RUN=yes, 1 (false) otherwise.
# Example:
#   if is_dry_run; then
#     echo "[DRY_RUN] would stream tar to S3"
#   else
#     tar cz -C /foo . | aws s3 cp - "s3://$BUCKET/foo.tgz"
#   fi
# Created: 2026-07-10
# ============================================================
is_dry_run() {
  [ "${DRY_RUN:-}" = "yes" ]
}

# ============================================================
# Function: run_or_echo
# Purpose:  Execute a single command, or preview it under DRY_RUN=yes.
#           Only for simple commands — pipelines and redirection
#           require an `if is_dry_run` block instead.
# Parameters:
#   $@ - Command and arguments to execute.
# Returns:  0 in dry-run mode; command's exit code otherwise.
# Example:
#   run_or_echo aws s3 rm "s3://bucket/key"
#   run_or_echo mysql -u root -e "DROP DATABASE IF EXISTS zinew;"
# Created: 2026-07-10
# ============================================================
run_or_echo() {
  if is_dry_run; then
    printf '%b[DRY_RUN]%b would run: %s\n' "$YELLOW" "$NC" "$*" >&2
    return 0
  fi
  "$@"
}

# ============================================================
# Function: log_init
# Purpose:  Set up dual-destination logging: everything printed by
#           the script from now on goes to BOTH the console AND
#           /var/log/worxco-migration/<script>-<UTC timestamp>.log.
#           The timestamped log file becomes the durable record;
#           log_upload_and_exit ships it to S3 at end.
# Parameters:
#   $1 - Short script name (e.g. "dump-mysql"). Used in filename.
# Side effects:
#   - Sets globals: LOG_DIR, LOG_FILE, LOG_SCRIPT
#   - Creates /var/log/worxco-migration if it doesn't exist
#     (uses sudo if the current user can't create it directly)
#   - Redirects stdout+stderr through `tee` for the rest of the script
# Returns: 0
# Dependencies: tee, mkdir, date, sudo (only if /var/log needs escalation)
# Created: 2026-07-10
# ============================================================
log_init() {
  local script_name="${1:-migration}"
  local timestamp
  timestamp=$(date -u +%Y%m%d-%H%M%SZ)

  LOG_DIR="/var/log/worxco-migration"
  LOG_FILE="${LOG_DIR}/${script_name}-${timestamp}.log"
  LOG_SCRIPT="$script_name"
  export LOG_DIR LOG_FILE LOG_SCRIPT

  # Create the log directory, escalating to sudo only if needed.
  # Chmod 1777 (sticky world-writable, like /tmp) so any user in
  # the migration workflow can drop logs here.
  if [ ! -d "$LOG_DIR" ]; then
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
      sudo mkdir -p "$LOG_DIR"
      sudo chmod 1777 "$LOG_DIR"
    fi
  fi

  # Route stdout+stderr through tee for the remainder of the script.
  # Note: `exec` here is fd manipulation, not process replacement —
  # the tee runs as a background child receiving all subsequent output.
  exec > >(tee -a "$LOG_FILE") 2>&1

  printf '=== log_init: %s @ %s ===\n' "$script_name" "$timestamp"
}

# ============================================================
# Function: log_upload_and_exit
# Purpose:  Upload the local log file to S3 and exit with the script's
#           original outgoing exit code. Designed to be invoked from
#           a `trap ... EXIT` so it fires on both clean and error exits.
# Parameters:
#   $1 - S3 bucket name (no s3:// prefix). Optional; if omitted, log
#        is left in place locally and no upload is attempted.
# Behavior:
#   - Captures $? on line 1 so the outgoing exit code survives the trap
#   - Uploads to s3://<bucket>/logs/YYYY-MM-DD/<basename>
#   - On upload failure, leaves the local copy and prints a warning
#     (never masks the script's actual exit code)
# Returns: never — calls exit with the original code
# Dependencies: aws (CLI v2), basename
# Created: 2026-07-10
# ============================================================
log_upload_and_exit() {
  local exit_code=$?   # MUST be first line — captures the outgoing status
  local s3_bucket="${1:-}"

  # If logging was never initialized, or the file vanished, just exit.
  if [ -z "${LOG_FILE:-}" ] || [ ! -f "${LOG_FILE:-}" ]; then
    exit "$exit_code"
  fi

  # If no bucket was passed, keep the local log and exit.
  if [ -z "$s3_bucket" ]; then
    printf 'Log preserved locally at: %s (no S3 bucket specified)\n' \
      "$LOG_FILE" >&2
    exit "$exit_code"
  fi

  local date_prefix
  date_prefix=$(date -u +%Y-%m-%d)
  local remote="s3://${s3_bucket}/logs/${date_prefix}/$(basename "$LOG_FILE")"

  if aws s3 cp "$LOG_FILE" "$remote" >/dev/null 2>&1; then
    printf 'Log uploaded: %s\n' "$remote"
  else
    printf 'Warning: log upload to %s failed; local copy at %s\n' \
      "$remote" "$LOG_FILE" >&2
  fi

  exit "$exit_code"
}

# ============================================================
# Function: require_env
# Purpose:  Assert that all listed environment variables are set and
#           non-empty. Fails loud with a full list of missing vars,
#           so the operator gets all problems in one pass instead of
#           discovering them one at a time.
# Parameters:
#   $@ - Names of env vars to check (NOT their values — just names).
# Returns:  0 if all present; calls exit 1 with a listing otherwise.
# Example:
#   require_env MIGRATION_BUCKET DRUPAL_DB_HOST DRUPAL_DB_PASS
# Dependencies: bash (uses indirect variable expansion `${!var}`)
# Created: 2026-07-10
# ============================================================
require_env() {
  local missing=()
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    printf '%bERROR: Required environment variables missing:%b\n' \
      "$RED" "$NC" >&2
    for var in "${missing[@]}"; do
      printf '  %b%s%b\n' "$RED" "$var" "$NC" >&2
    done
    exit 1
  fi
}

# ============================================================
# Function: log_info / log_warn / log_error / log_ok / log_step
# Purpose:  Structured log lines with consistent visual style.
#           _step is for high-level phase headers.
# Parameters:
#   $@ - Message to log.
# Behavior:
#   - _info, _ok, _step go to stdout
#   - _warn, _error go to stderr
#   - Each is prefixed with a color-coded tag
# Created: 2026-07-10
# ============================================================
log_info()  { printf '%b[INFO]%b  %s\n'  "$BLUE"   "$NC" "$*"; }
log_ok()    { printf '%b[OK]%b    %s\n'  "$GREEN"  "$NC" "$*"; }
log_step()  { printf '\n%b=== %s ===%b\n' "$CYAN"  "$*"  "$NC"; }
log_warn()  { printf '%b[WARN]%b  %s\n'  "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n'  "$RED"    "$NC" "$*" >&2; }

# ============================================================
# Function: mask_secret
# Purpose:  Return a partially-obscured version of a string for
#           logging. Shows first 2 and last 2 characters with
#           "***" between; strings of 4 or fewer characters return
#           just "***" (no useful characters revealed).
# Parameters:
#   $1 - Secret value to mask.
# Returns:  Prints the masked value on stdout.
# Example:
#   log_info "Connecting as user=$DB_USER pass=$(mask_secret "$DB_PASS")"
#   # Output: [INFO] Connecting as user=drupal pass=zM***== (for len>4)
# Created: 2026-07-10
# ============================================================
mask_secret() {
  local s="${1:-}"
  local len=${#s}
  if [ "$len" -le 4 ]; then
    printf '***'
  else
    printf '%s***%s' "${s:0:2}" "${s: -2}"
  fi
}

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
