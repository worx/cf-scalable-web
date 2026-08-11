#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/rds-boosted-migration.sh
#
# Purpose:  Wrap an arbitrary migration command with RDS boost-before /
#           revert-after semantics. Trap ensures revert fires even if
#           the wrapped command fails, so RDS never gets stranded at
#           the expensive tier.
#
# Usage:    scripts/rds-boosted-migration.sh <env> <cmd> [args...]
#
# Example:  scripts/rds-boosted-migration.sh sandbox make migrate-db-all AUTO=yes
#
# Environment variables:
#   SKIP_RDS_BOOST=yes   Bypass both boost and revert; run the wrapped
#                        command as-is. Useful when the RDS baseline is
#                        already the target class (e.g., prod) or when
#                        wall time doesn't matter (dry-run iterations).
#
#   AWS_REGION           Passed through to rds-migration-tuning.sh
#
# Exit code: the wrapped command's exit code, preserved across the
#            revert step. If revert itself fails, the operator sees a
#            loud warning but the original exit code stands (so CI
#            sees the real result).
#
# Related:  scripts/rds-migration-tuning.sh (the boost + revert impl)
#
# Created:  2026-08-11
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
TUNING_SCRIPT="$SCRIPT_DIR/rds-migration-tuning.sh"

if [ "$#" -lt 2 ]; then
  cat >&2 <<USAGE
Usage: $0 <env> <cmd> [args...]

Wraps <cmd> with RDS boost-before / revert-after. Trap ensures revert
runs even on wrapped-command failure.

Example:
  $0 sandbox make migrate-db-all AUTO=yes
USAGE
  exit 2
fi

ENV="$1"; shift
# Remaining $@ is the command + its args.

# Escape hatch: bypass boost + revert entirely.
if [ "${SKIP_RDS_BOOST:-}" = "yes" ]; then
  echo "SKIP_RDS_BOOST=yes — running wrapped command WITHOUT RDS boost/revert"
  exec "$@"
fi

# Boost --async. Submits the RDS modify + saves the pre-boost config to
# SSM, then returns immediately WITHOUT waiting for RDS to reach
# 'available'. This lets the wrapped command's first step (usually
# restore-mysql on migrate-host) run CONCURRENTLY with the RDS reboot,
# saving 3-5 min per run. The pgloader dispatch step will call
# 'wait-if-boosting' before actually connecting to RDS — that's the
# gate that guarantees RDS is ready when it matters.
"$TUNING_SCRIPT" "$ENV" boost --async || {
  echo "ERROR: RDS boost failed; aborting before running wrapped command" >&2
  exit 1
}

# Trap: run revert on ANY exit (success, failure, signal). We capture
# the wrapped command's exit code AFTER trap fires so it becomes the
# script's outgoing exit code — revert failures do not mask migration
# results, they only produce a loud warning.
WRAPPED_STATUS=0
trap 'echo ""; echo ">>> revert-on-exit: restoring RDS to baseline..."; \
      "$TUNING_SCRIPT" "$ENV" revert || \
        echo "WARN: revert failed — check RDS console; may need manual restore" >&2; \
      exit $WRAPPED_STATUS' EXIT INT TERM

# Run the wrapped command. Capture its exit code without letting set -e
# abort us before the trap can fire the revert.
set +e
"$@"
WRAPPED_STATUS=$?
set -e

# Falling off here triggers the EXIT trap which runs revert + exits
# with $WRAPPED_STATUS.

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
