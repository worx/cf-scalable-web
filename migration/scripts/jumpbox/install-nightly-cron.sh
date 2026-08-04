#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# migration/scripts/jumpbox/install-nightly-cron.sh
#
# Purpose:  Install the nightly-dump wrapper + a crontab entry on the
#           jumpbox. Idempotent — safe to re-run to update.
#
# Flow:
#   1. Fetch latest nightly-dump-runner.sh from S3
#   2. Install to /opt/nightly-dumps/nightly-dump-runner.sh (executable)
#   3. Write a crontab entry (root's crontab) with the schedule +
#      env vars the wrapper needs
#   4. Show the resulting crontab
#
# Env vars (all optional):
#   MIGRATION_BUCKET   Sandbox S3 bucket (default: sandbox-migration-kv-worxco)
#   CRON_SCHEDULE      Cron schedule expression (default: "0 3 * * 2-6",
#                      = 3 AM UTC Tuesday through Saturday). Kurt runs
#                      the jumpbox in UTC; adjust if the jumpbox TZ
#                      differs, or override with your desired schedule.
#
# Runs as:  root on the jumpbox, dispatched by
#           `make deploy-nightly-cron` from Mac/deploy-host via SSM
#
# Idempotency: the crontab entry is marked with a distinctive comment
#              `# managed-by: install-nightly-cron.sh`; re-running
#              removes any prior marked entries before adding a fresh
#              one, so schedule changes take effect cleanly.
#
# Created:  2026-08-04

set -euo pipefail

MIGRATION_BUCKET="${MIGRATION_BUCKET:-sandbox-migration-kv-worxco}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 2-6}"
WRAPPER_S3_KEY="scripts/jumpbox/nightly-dump-runner.sh"
WRAPPER_DEST="/opt/nightly-dumps/nightly-dump-runner.sh"
CRON_MARKER="# managed-by: install-nightly-cron.sh"

echo "=== install-nightly-cron @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "  host:              $(hostname)"
echo "  MIGRATION_BUCKET:  $MIGRATION_BUCKET"
echo "  CRON_SCHEDULE:     $CRON_SCHEDULE"
echo "  wrapper location:  $WRAPPER_DEST"

# ------------------------------------------------------------
# 1. Fetch wrapper from S3
# ------------------------------------------------------------
echo ""
echo "--- Fetching wrapper ---"
mkdir -p /opt/nightly-dumps
aws s3 cp "s3://$MIGRATION_BUCKET/$WRAPPER_S3_KEY" "$WRAPPER_DEST"
chmod +x "$WRAPPER_DEST"
echo "✓ wrapper installed at $WRAPPER_DEST"

# ------------------------------------------------------------
# 2. Build the crontab entry
# ------------------------------------------------------------
# Wrapper handles its own logging (tee to /var/log/worxco-migration/),
# so cron just needs to fire it; output redirected to /dev/null
# (any real failure surfaces via the SNS notification the wrapper
# publishes).
CRON_LINE="$CRON_SCHEDULE MIGRATION_BUCKET=\"$MIGRATION_BUCKET\" $WRAPPER_DEST > /dev/null 2>&1  $CRON_MARKER"

# ------------------------------------------------------------
# 3. Install (idempotent — strip any existing marked lines first)
# ------------------------------------------------------------
echo ""
echo "--- Updating crontab for root ---"
# `crontab -l` exits 1 if no crontab exists; that's fine — we'll create one.
# `|| true` prevents `set -e` from bailing on that empty-crontab case.
EXISTING=$(crontab -l 2>/dev/null || true)
UPDATED=$(printf '%s\n' "$EXISTING" | grep -v "$CRON_MARKER" | grep -v '^$' || true)
printf '%s\n%s\n' "$UPDATED" "$CRON_LINE" | crontab -

echo "✓ crontab updated. Current entries managed by us:"
crontab -l | grep -F "$CRON_MARKER" | while read -r line; do
  echo "    $line"
done

echo ""
echo "=========================================="
echo "=== INSTALL COMPLETE ==="
echo "=========================================="
echo ""
echo "Next scheduled run: '$CRON_SCHEDULE' (UTC on this host)"
echo ""
echo "Sanity checks you can run right now:"
echo "  # verify cron service is active"
echo "  systemctl status cron   # (or crond)"
echo ""
echo "  # trigger the wrapper manually (safe — same as scheduled run)"
echo "  sudo $WRAPPER_DEST"
echo ""
echo "  # enable SNS failure notifications (optional):"
echo "  aws ssm put-parameter --name /migration/nightly-cron/sns-topic-arn \\"
echo "    --value <topic-arn> --type String --overwrite --region us-east-1"
