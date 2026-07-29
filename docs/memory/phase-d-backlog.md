---
name: phase-d-backlog
description: Accumulated follow-up work items — infrastructure hardening, orchestrator polish, and architectural cleanups discovered during migration + destroy-all validation sessions. Not blocking; do when time permits.
metadata:
  type: project
---

# Phase D backlog

Items surfaced during the migration + rebuild validation work
(2026-07-28 through 2026-07-29). Grouped by subsystem. None are
blocking current operation; they're improvements/hardening that
turn "works if you know the manual steps" into "just works."

## destroy-all orchestrator (`scripts/destroy-all-parallel.py`)

- **Check-before-delete (aka "Option C").** Currently every TRACK
  ends with `|| true` in its cmd (line 68 for `s3` is representative).
  This swallows DELETE_FAILED and reports ✓. Fix: remove `|| true`
  from each cmd, then update each `destroy-*` Makefile target to
  distinguish "stack doesn't exist" (exit 0, expected on re-runs)
  from "delete-stack failed" (exit non-zero, real failure).
  Bug caught 2026-07-29 during first rebuild test — sandbox media
  bucket had versioned objects, storage-s3 stack ended DELETE_FAILED,
  orchestrator reported ✓.

## cf-storage-s3.yaml

- **Lambda-backed purge-on-delete for versioned MediaBucket.**
  Canonical AWS pattern: on stack DELETE, a custom resource wipes
  versions + delete markers so CFN's built-in bucket-delete can
  complete. Without this, every destroy-all after a sync-s3-media
  operation hits the same wall we hit 2026-07-29 (5535 delete markers
  left CFN unable to delete the bucket).

- **LifecycleConfiguration: `NoncurrentVersionExpiration: NoncurrentDays: 1`.**
  Belt-and-suspenders alongside the Lambda purge. Auto-expires old
  versions after 1 day so a normally-operating bucket doesn't
  accumulate version cruft over time.

## cf-migration-jumpbox.yaml + cf-migration-bucket.yaml (prod-account)

- **Same auto-purge pattern for the migration bucket.** If we ever
  destroy + recreate cf-migration-bucket, the same version-blocks-
  delete problem applies. Different account (prod), so plumbing needs
  to work there too.

## cf-app-drupal.yaml

- **Document that this stack survives destroy-all by design.** The
  Secrets Manager entries (DrupalAdminPasswordSecret,
  DrupalDBPasswordSecret) and SSM parameters here are intentionally
  long-lived per environment — they provide identity continuity
  across cost-cycling (pause-compute / resume-compute) and full
  destroy → redeploy cycles. Kurt confirmed 2026-07-29.
  Related: hash-salt secret (`worxco/${ENV}/drupal/hash-salt`) is
  ALSO designed to survive, but it's owned by install-drupal.sh
  rather than by any CFN stack. See
  [[salt-persistence-design]] for why.
  Add a comment block to the top of cf-app-drupal.yaml and to the
  destroy-all-parallel TRACKS section explaining the exclusion.

- **Add `destroy-app-drupal` Makefile target.** Explicit,
  operator-invoked-only escape hatch for the rare case someone
  genuinely wants to nuke the per-env credentials and start fresh.
  Not part of destroy-all.

## migration script polish

- **Age-based auto-prune option for `.BAK` dirs.** `make
  clean-migration-baks` currently deletes ALL matching dirs.
  Optional flag `MAX_AGE_DAYS=30` would only delete BAKs older
  than N days, so recent BAKs (still useful for rollback) survive.
  Nice-to-have.

- **`dispatch-clean-migration-baks.sh` improvements.** Currently
  detects deploy-host via `/etc/worxco` + NFS `/var/www` — that
  works. Consider generalizing the pattern into a reusable
  "am I on the deploy-host?" bash function that other scripts can
  source. Low priority.

## install-drupal / verify hooks

- **`install-drupal-full` should verify flysystem block landed.**
  Currently, `install-drupal.sh` writes the flysystem_s3 block into
  settings.php from the template, but nothing verifies it did. A
  post-install `grep` for the marker + PHP `-l` syntax check would
  catch template regressions before they manifest as production
  Drupal errors.

## Codebase migration completeness

- **`vendor/zoning-info/` empty despite auto-loading working.**
  During 2026-07-28 debugging, we discovered that after
  `composer install`, the two custom local packages
  (entity_bundle_manager, filtered_entity_reference) had their
  code loading correctly (bundle-class registration worked) BUT
  `vendor/zoning-info/` was empty. Some other mechanism (bca?
  Drupal module discovery?) was finding them outside composer's
  autoloader. Works in practice but architecturally opaque.
  Understanding it → a real fix once we know what's going on.

- **The 4 unmapped `zi_research_document` bundle classes.**
  See [[research-document-bundle-gaps]] — waiting on Zac's review
  of whether these need bundle-class subclasses (with
  `getResearchAnswer()`) or the calling code needs
  `method_exists` guards.

## LaTeX / PDF generation → Lambda

See [[pdf-generation-lambda-candidates]] — two Drupal routes that
504 on synchronous PHP-FPM PDF generation. Waiting on Lambda
architecture decision before implementing.

## Fresh sandbox rebuild — full end-to-end migration test

Once the Phase D fixes above are in, do a full `make destroy-all` →
`make deploy-all` → `make install-drupal-full` → all-4-dumps →
all-4-restores → smoke test to prove the whole thing works from
bare AWS accounts. Migration test coverage:
- Codebase (with 2 siblings — auto-discovery)
- Database (mysql + pgloader chain)
- Public files (drupal-files.tar.gz)
- Private files (drupal-private.tar.gz)
