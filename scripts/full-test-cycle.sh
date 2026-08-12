#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# scripts/full-test-cycle.sh
#
# Purpose:  End-to-end from-scratch deploy + migrate + smoke-test cycle
#           for the sandbox environment. Empirically validated 2026-08-11.
#           Runs deploy-all → parallel(migrate-host + install-drupal + DNS)
#           → boosted DB migration on migrate-host → destroy migrate-host
#           → file/media/private/codebase restores → cache flush →
#           smoke tests → done.
#
# Wall time: ~65-80 min end-to-end (varies mostly with prod media size in
#            Phase 5-8 sync-s3-media).
#
# Cost:     ~$1.70 per run at sandbox tier + whatever the sandbox costs
#           while you leave it running afterward.
#
# Usage:    scripts/full-test-cycle.sh                # ENV=sandbox default
#           ENV=sandbox scripts/full-test-cycle.sh
#           AUTO=no scripts/full-test-cycle.sh        # disable install-drupal auto-fixup
#
# Environment variables:
#   ENV     Target environment (default: sandbox)
#   AUTO    Passed to migrate-db-all: 'yes' triggers auto-install-drupal
#           on preflight fail (default: yes for unattended runs).
#
# Runs as:  operator with ZI-Sandbox profile. Works from Mac or deploy-host.
#
# Logging:  tee'd to /tmp/full-test-<UTC>.log alongside stdout so the
#           terminal shows live progress AND the log survives for
#           post-mortem grep.
#
# Prerequisites:
#   1. `git pull` on whichever host runs this (so PHP74_ENABLED macro
#      and pgloader marker-guards are current).
#   2. Kurt's per-env param file changes (e.g. compute-php-sandbox.json
#      EnablePHP74=false) must be committed OR present in the working
#      tree of the host running this — the PHP74_ENABLED Make macro
#      reads the file at parse time.
#   3. Prod dumps must be reasonably fresh in the migration S3 bucket
#      (`make dump-all` from the jumpbox nightly cron handles this).
#
# See also:
#   - docs/plans/migrate-host-design-2026-08-05.md   (design rationale)
#   - scripts/rds-migration-tuning.sh                (boost/revert impl)
#   - scripts/rds-boosted-migration.sh               (trap-and-run wrapper)
#
# Created:  2026-08-11
# ============================================================

set -euo pipefail

ENV="${ENV:-sandbox}"
AUTO="${AUTO:-yes}"
LOG_FILE="/tmp/full-test-$(date +%Y%m%d-%H%M%S).log"

echo "============================================"
echo "  Full test cycle — ENV=$ENV AUTO=$AUTO"
echo "  Log: $LOG_FILE"
echo "============================================"
echo ""

# Everything below runs inside a single subshell so its stdout can be
# tee'd to the log. `set -e` propagates through the subshell so any
# unhandled failure aborts before continuing to later phases.
{
  # =========================================================
  # Phase 1: sandbox infrastructure (~35-40 min)
  # =========================================================
  echo ""
  echo "### PHASE 1/11: deploy-all"
  make deploy-all ENV="$ENV" || exit 1

  # =========================================================
  # Phase 2: migrate-host + install-drupal + publish-dns (parallel, ~5-6 min max)
  # =========================================================
  # deploy-migrate-host runs concurrent with install-drupal-remote +
  # publish-dns. All three depend on Phase 1 but not on each other.
  # Longest of the three (deploy-migrate-host at ~5-6 min) sets the
  # wall time for this phase.
  echo ""
  echo "### PHASE 2/11: deploy-migrate-host (bg) + install-drupal + publish-dns"

  make deploy-migrate-host &
  MIGRATE_PID=$!

  make install-drupal-remote ENV="$ENV" && make publish-dns ENV="$ENV"
  FG_STATUS=$?

  wait "$MIGRATE_PID"
  MIGRATE_STATUS=$?

  if [ "$FG_STATUS" -ne 0 ]; then
    echo "ERROR: install-drupal-remote or publish-dns failed (status=$FG_STATUS)" >&2
    exit 1
  fi
  if [ "$MIGRATE_STATUS" -ne 0 ]; then
    echo "ERROR: deploy-migrate-host failed (status=$MIGRATE_STATUS)" >&2
    exit 1
  fi

  # =========================================================
  # Phase 3: DB migration on migrate-host with RDS boost (~15-18 min)
  # =========================================================
  # HOST_STACK=cf-migrate-host redirects dispatch-restore-mysql +
  # dispatch-run-pgloader to migrate-host. migrate-db-all-boosted wraps
  # in RDS boost --async (parallel with restore-mysql), then
  # wait-if-boosting gates pgloader on RDS ready, then trap-revert
  # restores RDS to the baseline db.t4g.micro on exit.
  echo ""
  echo "### PHASE 3/11: migrate-db-all-boosted (HOST_STACK=cf-migrate-host)"
  (cd migration && HOST_STACK=cf-migrate-host make migrate-db-all-boosted ENV="$ENV" AUTO="$AUTO") || exit 1

  # =========================================================
  # Phase 4: destroy migrate-host early (~3 min)
  # =========================================================
  # migrate-host's work is done. Destroying now saves ~30 min of
  # r7g.xlarge billing during the potentially-slow Phase 5-8 file syncs.
  # Auto-backup fires; state preserved in S3 for the next deploy's
  # auto-restore-from-S3 to pull back.
  echo ""
  echo "### PHASE 4/11: destroy migrate-host (auto-backup fires)"
  make destroy-migrate-host CONFIRMED=yes || exit 1

  # =========================================================
  # Phase 5-8: file / media / private / codebase restores
  # =========================================================
  # These target deploy-host (FSx mount) and the sandbox media S3 bucket.
  # Serial because dispatch-* scripts stage themselves through the same
  # migration S3 bucket path — concurrent invocations could clobber.
  # sync-s3-media is safe to parallelize (S3-to-S3, no host) but kept
  # serial here for simplicity + log readability.
  echo ""
  echo "### PHASE 5/11: sync-s3-media (prod media bucket -> sandbox)"
  (cd migration && make sync-s3-media CONFIRMED=yes) || exit 1

  echo ""
  echo "### PHASE 6/11: dispatch-restore-codebase (Drupal + modules from prod)"
  # CRITICAL ORDER: codebase FIRST (brings Commerce + other modules that
  # the migrated DB config references), then files/private. Reversing
  # this ordering will trigger PluginNotFoundException 500s until the
  # codebase catches up.
  (cd migration && make dispatch-restore-codebase CONFIRMED=yes) || exit 1

  echo ""
  echo "### PHASE 7/11: dispatch-restore-files (public files)"
  (cd migration && make dispatch-restore-files CONFIRMED=yes) || exit 1

  echo ""
  echo "### PHASE 8/11: dispatch-restore-private (private files)"
  (cd migration && make dispatch-restore-private CONFIRMED=yes) || exit 1

  # =========================================================
  # Phase 9-10: cache flush + OPcache clear (~30 sec)
  # =========================================================
  # migrate-db-all already ran clear-drupal-cache in its Phase 3 — but
  # that was BEFORE restore-codebase brought Commerce and prod's other
  # modules onto FSx. Any request Drupal served in that window will
  # have cached a partial/broken container state (PluginNotFoundException
  # for commerce_remote_id, etc.). Clearing again NOW forces Drupal to
  # rebuild with the full module tree.
  echo ""
  echo "### PHASE 9/11: clear-drupal-cache (second time — after codebase restore)"
  make clear-drupal-cache ENV="$ENV" || exit 1

  echo ""
  echo "### PHASE 10/11: restart-php-fpm (OPcache flush)"
  make restart-php-fpm ENV="$ENV" || exit 1

  # =========================================================
  # Phase 11: smoke tests
  # =========================================================
  # smoke-test-drupal uses curl --resolve (DNS-bypassed) — proves the
  # ALB+nginx+PHP-FPM+Drupal path works.
  # smoke-test-public uses real DNS — proves the Route 53 alias resolves
  # and end-to-end is reachable from the operator's machine.
  # Both should return HTTP 200.
  echo ""
  echo "### PHASE 11/11: smoke tests (DNS-bypassed + through-DNS)"
  make smoke-test-drupal ENV="$ENV" || exit 1
  make smoke-test-public ENV="$ENV" || exit 1

  echo ""
  echo "============================================"
  echo "  ✓ FULL TEST CYCLE PASSED"
  echo "============================================"
} 2>&1 | tee "$LOG_FILE"

# Preserve the pipeline's real exit code (`tee` always exits 0, so
# without pipefail we'd lie about success). set -euo pipefail at the
# top handles this, but be explicit for the operator reading the code.
exit "${PIPESTATUS[0]}"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
