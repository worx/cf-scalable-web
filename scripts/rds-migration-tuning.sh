#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/rds-migration-tuning.sh
#
# Purpose:  Temporarily upsize (or restore) the sandbox RDS instance
#           for the duration of a migration. Wraps `aws rds modify-
#           db-instance` with save/restore semantics so any revert
#           returns RDS to exactly the class/IOPS/throughput it had
#           at boost time.
#
#           RDS at db.t4g.micro + gp3 defaults (3000 IOPS / 125 MB/s)
#           is the pgloader bottleneck — measured 50-52 min wall
#           clock on both deploy-host AND migrate-host against this
#           config (2026-08-06 and 2026-08-11 test runs). Bumping to
#           db.r7g.xlarge + 10K IOPS / 500 MB/s during the migration
#           and reverting after should shave 30-40 min per run.
#
# Flow:
#   boost:
#     1. Look up DBInstanceIdentifier from CFN output
#     2. Read CURRENT class + IOPS + throughput + storage type
#     3. Save as JSON to SSM parameter /<env>/rds/pre-migration-config
#     4. aws rds modify-db-instance to target values (--apply-immediately)
#     5. Wait for DBInstanceStatus=available (30-min ceiling)
#
#   revert:
#     1. Look up DBInstanceIdentifier from CFN output
#     2. Read saved values from SSM parameter
#     3. aws rds modify-db-instance back to saved values (--apply-immediately)
#     4. Wait for DBInstanceStatus=available
#     5. Delete SSM parameter (transaction complete)
#
# Idempotency:
#   boost with SSM parameter already present -> refuses (must revert
#     first, or manually delete the parameter to unstick). Prevents
#     stacking multiple "current" snapshots and losing the real one.
#   revert with SSM parameter absent -> warns + exits 0 (nothing to
#     revert to; may already be reverted).
#
# Usage:    scripts/rds-migration-tuning.sh <env> boost  [--target-class CLASS] [--target-iops N] [--target-throughput N]
#           scripts/rds-migration-tuning.sh <env> revert
#
# Defaults:
#   --target-class       db.r7g.xlarge  (4 vCPU / 32 GiB)
#   --target-iops        10000
#   --target-throughput  500  (MB/s)
#
# Environment variables:
#   AWS_REGION  Region for all ops     (us-east-1)
#
# Runs as:  operator (Mac or deploy-host) with ZI-Sandbox profile
# Cost:     ~$0.13 per migration ($0.38/hr db.r7g.xlarge, ~20 min
#           of the boosted window that actually saves time)
#
# Created:  2026-08-11
# ============================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="--profile ZI-Sandbox"
STACK_PREFIX="cf-scalable-web"

# Defaults. IOPS/throughput are UNSET by default because RDS requires
# gp3 storage ≥ 400 GiB before allowing custom IOPS/throughput, and
# storage size is one-way (you can grow it but never shrink) — bumping
# a 20 GiB sandbox to 400 GiB just for IOPS-per-migration would create
# a permanent $30-40/mo storage floor. Class-only boost still delivers
# the vast majority of the win. To enable IOPS/throughput bump, pass
# --target-iops N (and optionally --target-throughput N) explicitly.
TARGET_CLASS="db.r7g.xlarge"
TARGET_IOPS=""          # empty = don't modify
TARGET_THROUGHPUT=""    # empty = don't modify

# RDS enforcement: storage must be >= this GiB before IOPS/throughput
# can be modified above the gp3 baseline.
GP3_MIN_STORAGE_FOR_IOPS_GIB=400

# ============================================================
# Helpers
# ============================================================
usage() {
  cat >&2 <<USAGE
Usage:
  $0 <env> boost  [--target-class CLASS] [--target-iops N] [--target-throughput N]
  $0 <env> revert

Defaults for boost:
  --target-class       $TARGET_CLASS
  --target-iops        (unset — do not modify. Set only if storage >= 400 GiB.)
  --target-throughput  (unset — do not modify. Set only if storage >= 400 GiB.)
USAGE
  exit 2
}

# Simple colored logging (no dependency on _common.sh — this script is
# invoked from Mac + deploy-host + migrate-host; _common.sh isn't
# always on the caller's path).
if [ -t 1 ]; then
  RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; YELLOW=""; GREEN=""; BLUE=""; CYAN=""; NC=""
fi
log_info()  { printf "%b[INFO]%b  %s\n"  "$BLUE"   "$NC" "$*"; }
log_ok()    { printf "%b[OK]%b    %s\n"  "$GREEN"  "$NC" "$*"; }
log_warn()  { printf "%b[WARN]%b  %s\n"  "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf "%b[ERROR]%b %s\n"  "$RED"    "$NC" "$*" >&2; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      log_error "Required command '$c' not on PATH."
      exit 1
    }
  done
}

# Look up the DBInstanceIdentifier from the database stack's CFN outputs.
# Env is verified against the stack existing — a bad env name will fail
# here rather than deeper inside AWS calls.
lookup_instance_id() {
  local env="$1"
  local stack="${STACK_PREFIX}-${env}-database"
  local id
  id=$(aws $AWS_PROFILE_ARG cloudformation describe-stacks \
        --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='DBInstanceIdentifier'].OutputValue" \
        --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    log_error "Could not resolve DBInstanceIdentifier from stack '$stack'."
    log_error "  Is the database stack deployed for env '$env'?"
    log_error "  Check: aws cloudformation describe-stacks --stack-name $stack"
    exit 1
  fi
  printf '%s' "$id"
}

# Get current DBInstanceClass, AllocatedStorage, Iops, StorageThroughput,
# StorageType as JSON. Includes StorageAllocated because RDS's ≥400 GiB
# rule for custom IOPS/throughput is checked against it before boost.
get_current_config() {
  local instance_id="$1"
  aws $AWS_PROFILE_ARG rds describe-db-instances \
    --db-instance-identifier "$instance_id" \
    --query 'DBInstances[0].{Class:DBInstanceClass,StorageGiB:AllocatedStorage,Iops:Iops,Throughput:StorageThroughput,Type:StorageType,Status:DBInstanceStatus}' \
    --output json --region "$AWS_REGION"
}

# aws rds wait — polls every 30s, up to 60 attempts (30 min). During an
# instance-class modify with --apply-immediately, the instance status
# briefly moves from "available" -> "modifying" -> "available". Give AWS
# a beat before we start waiting so we don't return prematurely from a
# stale "available" reading. 15s beats every observed race.
wait_available() {
  local instance_id="$1"
  local action="$2"  # boost | revert (for the message)
  log_info "Sleeping 15s so RDS moves out of 'available' before waiting..."
  sleep 15
  log_info "Waiting for DBInstanceStatus=available after $action (up to 30 min)..."
  # aws rds wait has no built-in progress; we print a heartbeat every 60s
  # in the background so the operator knows we're still alive.
  (
    while true; do
      sleep 60
      printf "  ...still waiting for RDS to stabilize\n"
    done
  ) &
  local heartbeat_pid=$!
  trap "kill $heartbeat_pid 2>/dev/null || true" EXIT INT TERM

  if aws $AWS_PROFILE_ARG rds wait db-instance-available \
       --db-instance-identifier "$instance_id" --region "$AWS_REGION"; then
    kill "$heartbeat_pid" 2>/dev/null || true
    trap - EXIT INT TERM
    log_ok "RDS reports available"
  else
    kill "$heartbeat_pid" 2>/dev/null || true
    trap - EXIT INT TERM
    log_error "wait db-instance-available failed or timed out."
    log_error "Check RDS console — DB may still be modifying."
    return 1
  fi
}

# ============================================================
# Subcommands
# ============================================================
boost() {
  local env="$1"
  local instance_id
  instance_id=$(lookup_instance_id "$env")
  local ssm_name="/${env}/rds/pre-migration-config"

  log_info "Target instance: $instance_id"
  log_info "SSM param:       $ssm_name"

  # Refuse to boost if a saved config already exists (would clobber it).
  if aws $AWS_PROFILE_ARG ssm get-parameter --name "$ssm_name" \
       --region "$AWS_REGION" >/dev/null 2>&1; then
    log_error "SSM parameter '$ssm_name' already exists — a prior boost is unreverted."
    log_error "Fix by running:  $0 $env revert"
    log_error "  (or delete the parameter manually if you know it's stale:)"
    log_error "  aws ssm delete-parameter --name $ssm_name --region $AWS_REGION"
    exit 1
  fi

  log_info "Reading current RDS config..."
  local current
  current=$(get_current_config "$instance_id")
  echo "$current" | sed 's/^/  /'

  local storage_type storage_gib
  storage_type=$(echo "$current" | jq -r '.Type')
  storage_gib=$(echo "$current" | jq -r '.StorageGiB')
  if [ "$storage_type" != "gp3" ]; then
    log_error "This script only supports gp3 storage; current type is '$storage_type'."
    log_error "Manual RDS operator intervention required."
    exit 1
  fi

  # Decide whether to modify IOPS/throughput based on: user asked (via
  # --target-iops/--target-throughput) AND storage is large enough.
  # RDS rejects IOPS/throughput on gp3 volumes < 400 GiB.
  local will_modify_iops=false
  if [ -n "$TARGET_IOPS" ] || [ -n "$TARGET_THROUGHPUT" ]; then
    if [ "$storage_gib" -lt "$GP3_MIN_STORAGE_FOR_IOPS_GIB" ]; then
      log_error "You asked for custom IOPS/throughput but storage is only ${storage_gib} GiB."
      log_error "RDS requires >= ${GP3_MIN_STORAGE_FOR_IOPS_GIB} GiB for custom gp3 IOPS/throughput."
      log_error "Either bump storage first (one-way — cannot shrink), or omit --target-iops."
      exit 1
    fi
    will_modify_iops=true
  fi

  # Record what we're going to modify in the saved config, so revert
  # knows what to restore vs leave alone.
  local enriched
  enriched=$(echo "$current" | jq --arg wmi "$will_modify_iops" '. + {WillModifyIops: ($wmi == "true")}')

  log_info "Saving current config to $ssm_name..."
  aws $AWS_PROFILE_ARG ssm put-parameter \
    --name "$ssm_name" \
    --type String \
    --value "$enriched" \
    --overwrite \
    --region "$AWS_REGION" \
    --description "Auto-saved pre-migration RDS config for env=$env by rds-migration-tuning.sh" \
    >/dev/null
  log_ok "Saved."

  # Cleanup trap: if anything below fails, delete the SSM param we just
  # wrote so the next boost attempt isn't blocked by "already exists".
  # Cleared on successful completion.
  trap "log_warn 'boost failed — cleaning up SSM parameter'; \
        aws $AWS_PROFILE_ARG ssm delete-parameter --name '$ssm_name' \
          --region '$AWS_REGION' 2>/dev/null || true" EXIT

  # Build the modify command dynamically — only include IOPS/throughput
  # flags if we've decided to modify them.
  local modify_desc="class=$TARGET_CLASS"
  local -a modify_args=(--db-instance-class "$TARGET_CLASS")
  if [ "$will_modify_iops" = "true" ]; then
    modify_desc="$modify_desc iops=$TARGET_IOPS throughput=$TARGET_THROUGHPUT"
    [ -n "$TARGET_IOPS" ]       && modify_args+=(--iops "$TARGET_IOPS")
    [ -n "$TARGET_THROUGHPUT" ] && modify_args+=(--storage-throughput "$TARGET_THROUGHPUT")
  else
    modify_desc="$modify_desc (iops/throughput unchanged — storage < ${GP3_MIN_STORAGE_FOR_IOPS_GIB} GiB or not requested)"
  fi

  log_info "Modifying RDS to target: $modify_desc"
  aws $AWS_PROFILE_ARG rds modify-db-instance \
    --db-instance-identifier "$instance_id" \
    "${modify_args[@]}" \
    --apply-immediately \
    --region "$AWS_REGION" >/dev/null
  log_ok "Modify request submitted."

  wait_available "$instance_id" "boost"

  # Success — clear the failure-cleanup trap so revert can be called
  # normally later. wait_available may have set its own trap; we restore
  # to no-op.
  trap - EXIT INT TERM

  log_ok "Boost complete — RDS is now $modify_desc."
  log_info "Remember: run '$0 $env revert' after your migration completes."
}

revert() {
  local env="$1"
  local instance_id
  instance_id=$(lookup_instance_id "$env")
  local ssm_name="/${env}/rds/pre-migration-config"

  log_info "Target instance: $instance_id"
  log_info "SSM param:       $ssm_name"

  local saved
  saved=$(aws $AWS_PROFILE_ARG ssm get-parameter --name "$ssm_name" \
            --query 'Parameter.Value' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -z "$saved" ]; then
    log_warn "SSM parameter '$ssm_name' not found — nothing to revert to."
    log_warn "This means either (a) boost was never run, or (b) revert already ran."
    log_warn "No-op; exiting successfully."
    exit 0
  fi

  local saved_class saved_iops saved_throughput saved_will_modify_iops
  saved_class=$(echo "$saved" | jq -r '.Class')
  saved_iops=$(echo "$saved" | jq -r '.Iops')
  saved_throughput=$(echo "$saved" | jq -r '.Throughput')
  # WillModifyIops may be absent on records written by older versions of
  # this script — default to false (safest — never touches IOPS on revert).
  saved_will_modify_iops=$(echo "$saved" | jq -r '.WillModifyIops // false')

  # Read CURRENT state to decide if a modify is even needed. If the class
  # already matches the saved baseline (e.g., boost failed before it
  # actually applied), skip the modify — just delete the SSM parameter.
  local current_class
  current_class=$(get_current_config "$instance_id" | jq -r '.Class')

  if [ "$current_class" = "$saved_class" ] && [ "$saved_will_modify_iops" != "true" ]; then
    log_info "RDS is already at saved baseline (class=$current_class); skipping modify."
  else
    local restore_desc="class=$saved_class"
    local -a restore_args=(--db-instance-class "$saved_class")
    if [ "$saved_will_modify_iops" = "true" ]; then
      restore_desc="$restore_desc iops=$saved_iops throughput=$saved_throughput"
      restore_args+=(--iops "$saved_iops" --storage-throughput "$saved_throughput")
    fi

    log_info "Restoring RDS to: $restore_desc"
    aws $AWS_PROFILE_ARG rds modify-db-instance \
      --db-instance-identifier "$instance_id" \
      "${restore_args[@]}" \
      --apply-immediately \
      --region "$AWS_REGION" >/dev/null
    log_ok "Modify request submitted."

    wait_available "$instance_id" "revert"
  fi

  log_info "Deleting SSM parameter (transaction complete)..."
  aws $AWS_PROFILE_ARG ssm delete-parameter --name "$ssm_name" \
    --region "$AWS_REGION" >/dev/null
  log_ok "Revert complete — RDS is back to baseline (class=$saved_class)."
}

# ============================================================
# Argument parsing
# ============================================================
[ $# -lt 2 ] && usage

ENV="$1"; shift
SUBCOMMAND="$1"; shift

# Common preflight
require_cmd aws jq

# Parse subcommand flags
while [ $# -gt 0 ]; do
  case "$1" in
    --target-class)       TARGET_CLASS="$2";      shift 2 ;;
    --target-iops)        TARGET_IOPS="$2";       shift 2 ;;
    --target-throughput)  TARGET_THROUGHPUT="$2"; shift 2 ;;
    *) log_error "Unknown flag: $1"; usage ;;
  esac
done

case "$SUBCOMMAND" in
  boost)  boost  "$ENV" ;;
  revert) revert "$ENV" ;;
  *)      usage ;;
esac

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
