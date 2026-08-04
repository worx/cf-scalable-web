#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/remove-nightly-cron.sh
#
# Purpose:  Remove the nightly-dump-runner crontab entry from the
#           jumpbox. Idempotent — no-op if nothing was installed.
#           Preserves the wrapper script at /opt/nightly-dumps/ so
#           reinstall is fast + manual sudo invocation still works
#           (delete /opt/nightly-dumps/ separately if you want a
#           full cleanup).
#
# Runs as:  root on the jumpbox, dispatched by
#           `make remove-nightly-cron` from Mac/deploy-host via SSM
#
# Created:  2026-08-04

set -euo pipefail

CRON_MARKER="# managed-by: install-nightly-cron.sh"

echo "=== remove-nightly-cron @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "  host: $(hostname)"

EXISTING=$(crontab -l 2>/dev/null || true)
BEFORE=$(printf '%s\n' "$EXISTING" | grep -cF "$CRON_MARKER" || true)

if [ "$BEFORE" -eq 0 ]; then
  echo ""
  echo "  (no managed cron entries found — nothing to remove)"
  exit 0
fi

echo ""
echo "  found $BEFORE managed cron entries; removing..."

UPDATED=$(printf '%s\n' "$EXISTING" | grep -v "$CRON_MARKER" | grep -v '^$' || true)
if [ -z "$UPDATED" ]; then
  # If the ONLY entries were ours, we still have to tell crontab explicitly.
  # `crontab -r` removes the crontab entirely; safer than piping empty.
  crontab -r 2>/dev/null || true
  echo "  removed the ONLY cron entries (crontab now empty)"
else
  printf '%s\n' "$UPDATED" | crontab -
  echo "  removed managed entries; other crontab lines preserved"
fi

echo ""
echo "✓ REMOVE COMPLETE"
echo ""
echo "Wrapper still installed at /opt/nightly-dumps/nightly-dump-runner.sh"
echo "  - runnable manually with:  sudo /opt/nightly-dumps/nightly-dump-runner.sh"
echo "  - delete with:             sudo rm -rf /opt/nightly-dumps"
