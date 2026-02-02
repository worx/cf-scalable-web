#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# Script Name: prompt-logger.sh
# Purpose: Automated prompt logging for ISO 27001 audit trail (per-prompt model)
# Requirements: jq, date
# Dependencies: jq, date, git
# Date Created: 2026-01-28
#
# Change Log:
#   2026-01-28 - Initial version (session-based model)
#   2026-02-02 - Rewritten to per-prompt model for reliability
#
# Each UserPromptSubmit creates a new log file. No session state dependency.
# This eliminates stale pointer issues when SessionEnd doesn't fire.
#

set -o errexit
set -o nounset
set -o pipefail

# Configuration
DEVELOPER_INITIALS="KV"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROMPT_LOGS_DIR="${PROJECT_DIR}/PROMPT_LOGS"
CURRENT_PROMPT_FILE="${PROMPT_LOGS_DIR}/.current_prompt"

# Ensure logs directory exists
mkdir -p "$PROMPT_LOGS_DIR"

# Function: generate_filename
# Purpose: Generate a unique filename based on WorxCo naming convention
# Parameters: none
# Returns: filename string (YYYYMMDD-WKNN-HHMMSS-KV.md)
# Dependencies: date
# Created: 2026-01-28
generate_filename() {
  local date_str
  local week_str
  local time_str
  date_str=$(date +%Y%m%d)
  week_str="WK$(date +%V)"
  time_str=$(date +%H%M%S)
  echo "${date_str}-${week_str}-${time_str}-${DEVELOPER_INITIALS}.md"
}

# Function: get_current_prompt_log
# Purpose: Read the current prompt log file path from the pointer file
# Parameters: none
# Returns: filepath string, or empty if no current prompt
# Dependencies: none
# Created: 2026-02-02
get_current_prompt_log() {
  if [[ -f "$CURRENT_PROMPT_FILE" ]]; then
    local filepath
    filepath=$(cat "$CURRENT_PROMPT_FILE")
    if [[ -f "$filepath" ]]; then
      echo "$filepath"
      return 0
    fi
  fi
  echo ""
  return 0
}

# Function: init_log_file
# Purpose: Create a new log file with standard header metadata
# Parameters: $1 = log file path, $2 = session_id (optional)
# Returns: 0 on success
# Dependencies: git, date, whoami, hostname
# Created: 2026-01-28
init_log_file() {
  local log_file="$1"
  local session_id="${2:-unknown}"
  local project_name
  local git_branch
  project_name=$(basename "$PROJECT_DIR")
  git_branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "N/A")

  cat > "$log_file" << EOF
# AI Prompt Log

**Date**: $(date '+%Y-%m-%d %H:%M:%S')
**Week**: $(date +%V)
**AI System**: Claude Opus 4.5
**Project**: ${project_name}
**Session ID**: ${session_id}

---

## Metadata

- Developer: ${DEVELOPER_INITIALS}
- User: $(whoami)
- Host: $(hostname)
- PWD: ${PROJECT_DIR}
- Git Branch: ${git_branch}

---

## Prompt Log

EOF
}

# Function: append_log
# Purpose: Append a timestamped entry to a log file
# Parameters: $1 = log file path, $2 = event type, $3 = content
# Returns: 0 on success
# Dependencies: date
# Created: 2026-01-28
append_log() {
  local log_file="$1"
  local event_type="$2"
  local content="$3"
  local timestamp
  timestamp=$(date '+%H:%M:%S')

  {
    echo "### ${timestamp} - ${event_type}"
    echo ""
    echo "$content"
    echo ""
    echo "---"
    echo ""
  } >> "$log_file"
}

# Function: finalize_log
# Purpose: Append license footer to a log file
# Parameters: $1 = log file path
# Returns: 0 on success
# Dependencies: none
# Created: 2026-02-02
finalize_log() {
  local log_file="$1"
  {
    echo ""
    echo "<sub>**License:** GPL-2.0-or-later | **Copyright:** 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>"
  } >> "$log_file"
}

# Function: read_event_data
# Purpose: Read JSON event data from stdin (provided by Claude Code hooks)
# Parameters: none (reads stdin)
# Returns: JSON string
# Dependencies: none
# Created: 2026-01-28
read_event_data() {
  if [[ -t 0 ]]; then
    echo "{}"
  else
    cat
  fi
}

# Function: main
# Purpose: Route hook events to appropriate handlers
# Parameters: $1 = hook event name
# Returns: 0 on success
# Dependencies: all functions above, jq
# Created: 2026-01-28
main() {
  local hook_event="${1:-unknown}"
  local event_data
  event_data=$(read_event_data)

  # Extract session_id from event data (all hook events provide this)
  local session_id
  session_id=$(echo "$event_data" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

  case "$hook_event" in
    "UserPromptSubmit")
      # Create a new log file for each prompt
      local filename
      local filepath
      filename=$(generate_filename)
      filepath="${PROMPT_LOGS_DIR}/${filename}"

      # Initialize the new log file
      init_log_file "$filepath" "$session_id"

      # Save pointer to current prompt log
      echo "$filepath" > "$CURRENT_PROMPT_FILE"

      # Log the user prompt
      local prompt
      prompt=$(echo "$event_data" | jq -r '.prompt // "No prompt captured"' 2>/dev/null || echo "No prompt captured")
      append_log "$filepath" "User Prompt" "\`\`\`
${prompt}
\`\`\`"
      ;;

    "PostToolUse")
      # Append file modification info to current prompt log
      local log_file
      log_file=$(get_current_prompt_log)
      if [[ -z "$log_file" ]]; then
        return 0
      fi

      local tool_name
      local tool_input
      tool_name=$(echo "$event_data" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
      tool_input=$(echo "$event_data" | jq -r '.tool_input.file_path // .tool_input.command // "N/A"' 2>/dev/null || echo "N/A")

      if [[ "$tool_name" == "Write" || "$tool_name" == "Edit" ]]; then
        append_log "$log_file" "File Modified ($tool_name)" "- \`${tool_input}\`"
      fi
      ;;

    "Stop")
      # Finalize the current prompt log
      local log_file
      log_file=$(get_current_prompt_log)
      if [[ -z "$log_file" ]]; then
        return 0
      fi

      local stop_reason
      stop_reason=$(echo "$event_data" | jq -r '.stop_reason // "completed"' 2>/dev/null || echo "completed")
      append_log "$log_file" "Response Complete" "Stop reason: ${stop_reason}"
      finalize_log "$log_file"

      # Clean up pointer file
      rm -f "$CURRENT_PROMPT_FILE"
      ;;

    *)
      # Unknown event - ignore silently
      ;;
  esac
}

main "$@"
