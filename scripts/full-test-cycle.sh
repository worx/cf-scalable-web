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
# Wall time: ~55-70 min end-to-end (as of 2026-08-12 with sync-s3-media
#            pre-warm + background destroy-migrate-host optimizations —
#            revised down from the pre-optimization ~65-80 min budget).
#            Actual varies mainly with prod media size (sync-s3-media
#            wall time hidden behind deploy-all when small enough) and
#            deploy-all's own long pole.
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
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/full-test-$TS.log"
MEDIA_SYNC_LOG="/tmp/sync-media-$TS.log"
DESTROY_MIGRATE_LOG="/tmp/destroy-migrate-$TS.log"

echo "============================================"
echo "  Full test cycle — ENV=$ENV AUTO=$AUTO"
echo "  Main log:      $LOG_FILE"
echo "  Media sync log: $MEDIA_SYNC_LOG  (backgrounded)"
echo "  Destroy log:    $DESTROY_MIGRATE_LOG (backgrounded — Phase 4+)"
echo "============================================"
echo ""

# Everything below runs inside a single subshell so its stdout can be
# tee'd to the log. `set -e` propagates through the subshell so any
# unhandled failure aborts before continuing to later phases.
#
# The subshell also OWNS the backgrounded jobs (sync-s3-media pre-warm,
# destroy-migrate-host), because bash `wait $PID` only works for
# children of the CURRENT shell — starting them in the outer shell
# would make the inner `wait` calls fail with "not a child of this shell".
{
  # ============================================================
  # Trap: on any exit path (success or failure), kill any still-
  # running background jobs so we don't leave orphans. Jobs we've
  # already wait'd for are gone from the jobs table by then.
  # ============================================================
  trap 'jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true' EXIT

  # ============================================================
  # Pre-warm sync-s3-media in the background (optimization #3, 2026-08-12).
  # ============================================================
  # sync-s3-media only needs the sandbox media BUCKET to exist. That's
  # created ~30s into deploy-all by the storage-s3 CFN stack. The rest
  # of deploy-all (~35 min) plus fan-out (~5 min) plus migrate-db-all
  # (~15 min) all proceed independently of media sync. Pre-warming lets
  # the potentially-long media sync overlap with that whole ~55 min
  # window instead of running serially at Phase 5.
  #
  # The helper waits for cf-scalable-web-$ENV-storage-s3 to reach
  # CREATE_COMPLETE, then fires `make sync-s3-media CONFIRMED=yes`.
  # Output goes to a separate log — tail it in another terminal if you
  # want to watch progress live. wait'd for right before Phase 11.
  scripts/sync-s3-media-when-ready.sh "$ENV" > "$MEDIA_SYNC_LOG" 2>&1 &
  MEDIA_SYNC_PID=$!
  echo "### PRE-WARM: sync-s3-media (PID=$MEDIA_SYNC_PID) started in background"
  echo "              tail -f $MEDIA_SYNC_LOG"

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
  # Phase 4: destroy migrate-host in BACKGROUND (~3 min off critical path)
  # =========================================================
  # migrate-host's work is done. Destroying is a pure teardown — nothing
  # in Phases 5-11 depends on it. Backgrounding it removes ~3 min from
  # the critical path. Auto-backup still fires (it's inside the destroy
  # target); state preserved in S3 for the next deploy's auto-restore.
  # wait'd for at the very end so the operator learns of any failure
  # before the "PASSED" banner.
  echo ""
  echo "### PHASE 4/11: destroy migrate-host (backgrounded, auto-backup fires)"
  make destroy-migrate-host CONFIRMED=yes > "$DESTROY_MIGRATE_LOG" 2>&1 &
  DESTROY_MIGRATE_PID=$!
  echo "              PID=$DESTROY_MIGRATE_PID  tail -f $DESTROY_MIGRATE_LOG"

  # =========================================================
  # Phase 5-8: file restores + (media already pre-warmed at chain start)
  # =========================================================
  # File restores target deploy-host (FSx mount). Serial because dispatch-*
  # scripts stage themselves through the same migration S3 bucket path —
  # concurrent invocations could clobber each other's staged copies.
  #
  # sync-s3-media is NOT here anymore — it was kicked off at chain start
  # (optimization #3) and is running in the background. We wait for it
  # right before Phase 11 (smoke tests need media present to serve PDFs).
  echo ""
  echo "### PHASE 5/11: sync-s3-media SKIPPED (pre-warmed at chain start — wait'd for at Phase 11)"

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
  # Join pre-warmed sync-s3-media BEFORE Phase 11
  # =========================================================
  # Phase 11 loads PDFs which live in the sandbox media bucket. If the
  # background sync hasn't finished, smoke-test-public will 404 those
  # PDFs (or fetch stale). Wait now.
  echo ""
  echo "### JOIN: waiting for background sync-s3-media (PID=$MEDIA_SYNC_PID)"
  if wait "$MEDIA_SYNC_PID"; then
    echo "         sync-s3-media completed successfully"
  else
    MEDIA_STATUS=$?
    echo "ERROR: sync-s3-media failed with status $MEDIA_STATUS" >&2
    echo "       See $MEDIA_SYNC_LOG for details." >&2
    exit 1
  fi

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

  # =========================================================
  # Join backgrounded destroy-migrate-host (started at Phase 4)
  # =========================================================
  # Non-critical for the migration itself — this is just tearing down
  # the ephemeral migrate-host. But we DO want to know the outcome
  # before printing "PASSED", so we wait here rather than orphaning.
  echo ""
  echo "### JOIN: waiting for background destroy-migrate-host (PID=$DESTROY_MIGRATE_PID)"
  if wait "$DESTROY_MIGRATE_PID"; then
    echo "         destroy-migrate-host completed successfully"
  else
    DESTROY_STATUS=$?
    echo "WARN: destroy-migrate-host exited $DESTROY_STATUS (see $DESTROY_MIGRATE_LOG)" >&2
    echo "      Manual cleanup may be needed:  make destroy-migrate-host CONFIRMED=yes" >&2
    # Don't fail the whole test on a destroy hiccup — migration itself
    # succeeded, operator just needs to clean up the migrate-host stack.
  fi

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
