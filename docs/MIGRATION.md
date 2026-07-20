---
name: Migration overview (prod → sandbox / eventual prod cutover)
description: High-level overview of migration capabilities and when to use them. Points to migration/README.md for the executable runbook.
audience: operator + architect
created: 2026-06-12
updated: 2026-07-20
---

# Migration overview

Two questions this doc answers:

1. **When would you migrate vs fresh-install?**
2. **Where does each part of the migration workflow live?**

For the actual step-by-step runbook, see
**[`migration/README.md`](../migration/README.md)** — this doc is
scaffolding.

## When to migrate vs fresh-install

| Scenario | What to do |
|---|---|
| Testing a new sandbox from scratch, no need to see real data | `make install-drupal ENV=sandbox` — takes ~5-10 min, clean install |
| Rehearsing a prod-to-sandbox test with realistic data | Full migration flow (see runbook) |
| Testing schema/config changes against real content shapes | DB-only migration (see runbook Phase 1-5) |
| Making prod-affecting code changes and want a "does this still work?" pass | DB-only migration onto sandbox that has the new code deployed |
| Eventual prod cutover | Migration flow with production destination — patterns are the same, targeting differs (this doc will grow when we do the actual cutover) |

**Rule of thumb:** if the question is "does the app work?", fresh-install
is enough. If the question is "does the app work with prod's data
shapes/edge cases/scale?", migrate.

## The four capabilities

Migration is composed of four independent data flows. Pick what you
need — they compose but don't require each other:

| Flow | What moves | Prod-side action | Sandbox-side action |
|---|---|---|---|
| **Database** | prod MySQL → sandbox Postgres | `make dump-mysql` | `make restore-mysql` + `make run-pgloader` |
| **Codebase** | React2's `/var/www/drupal/` | `make dump-codebase` | (restore not yet wired — see follow-ups) |
| **Public files** | uploaded media, images | `make dump-files` | `make restore-files` |
| **Private files** | secure downloads, backups | `make dump-private` | `make restore-private` (preserves sandbox's salt.txt across atomic swap) |

Or: `make dump-all` runs all four dumps in one call.

**Composed pipelines** (the "usual" way to run migration):
- `make migrate-db-all` — DB-only chain (Phase -1 preflight → backup → restore-mysql → pgloader → cache-clear)
- `make migrate-full-all` — everything (migrate-db-all + files + private + second cache-clear)

Both walk-away safe (each phase dispatches via SSM; Mac sleep / terminal
close doesn't kill in-flight work). Both self-log to `/var/log/worxco-migration/`
on the deploy-host AND to `s3://<migration-bucket>/logs/YYYY-MM-DD/`.

`AUTO=yes` on either chain auto-invokes `install-drupal` if preflight
fails — for overnight runs where "wait, sandbox wasn't installed" is
worse than the 10 min autonomy cost of running install-drupal automatically.

See `migration/README.md` for the full runbook, env-var overrides, and
DB primitive targets (`db-backup` / `db-restore` / `list-db-backups`
/ `delete-db-backup`).

## Where things live

```
migration/                               ← the whole migration subsystem
├── README.md                            ← operator runbook (READ THIS FIRST)
├── Makefile                             ← all migration targets
├── cloudformation/                      ← per-phase CFN templates
│   ├── cf-migration-bucket.yaml
│   ├── cf-migration-secret.yaml
│   └── cf-migration-jumpbox.yaml
├── parameters/
├── pgloader/                            ← .load templates + docs
└── scripts/
    ├── _common.sh                       ← shared logging helpers
    ├── _ssm-run-jumpbox.sh              ← Mac → jumpbox dispatch
    ├── jumpbox/                         ← runs ON prod jumpbox
    └── deploy-host/                     ← runs ON sandbox deploy-host
```

Related repository areas:

- `scripts/deploy-host/` (top-level, not `migration/scripts/deploy-host/`)
  — contains `install-drupal.sh`, `use-env`, `refresh-env-config`, and
  friends. Migration workflow ASSUMES the deploy-host is already
  bootstrapped and has the toolchain (pgloader, mariadb-server, etc.)
- `docs/DEPLOY-HOST.md` — deploy-host lifecycle including how the
  toolchain gets on the box
- `docs/OPERATIONS.md` — day-to-day patterns (SSM, `use-env`,
  `clear-drupal-cache`, etc.)
- `docs/memory/db-rollback-pattern.md` — the DB rename dance used
  as the migration's rollback safety net
- `docs/memory/structural-checks-over-markers.md` — why the migration
  workflow doesn't rely on `.installed` markers for correctness

## Cross-account topology

```
   PROD account (978068244875)          SANDBOX account
   ==============================       ==========================

   React2 EC2 (Drupal)                  deploy-host EC2
     └── Aurora MySQL "zinew"             └── local MariaDB scratch
                                              (pgloader source)
   jumpbox EC2 (migration-only,
     private subnet, SSM-only) ─────►  S3 migration bucket
     ├── mysqldump                            (SANDBOX-side)
     ├── tar codebase                         │
     ├── tar files                            ▼
     └── tar private                    deploy-host reads from S3

                                        RDS PostgreSQL
                                          └── schema "zinew"
                                              (pgloader target)

                                        FSx OpenZFS
                                          └── /var/www/drupal
                                              (codebase, files)
```

**AWS profiles used:**
- `ZoningInfoAdmin` — prod actions (jumpbox lifecycle, dumps from
  React2)
- `ZI-Sandbox` — sandbox actions (bucket, restore, RDS, FSx)

The deploy-host uses its IAM instance role for all sandbox-side
operations — no `--profile` flag on scripts that run there.

## Historical note

An earlier version of this doc (2026-06-12) described the migration
workflow as a live SSM-tunneled pgloader run against React2's Aurora
MySQL directly. That approach was superseded during the July 2026
consolidation with the current dump-to-S3 + restore-locally pattern.
Rationale:

- **Reproducibility** — a dump captured to S3 can be re-loaded any
  number of times without re-touching prod
- **Isolation** — the pgloader source is now a local MariaDB scratch
  DB, not a live prod cluster. Bugs in pgloader can't degrade prod
  performance
- **Log durability** — dump-to-S3 provides an audit trail (what
  data was actually pulled and when) that live-tunneling didn't
- **Retry cost** — re-running pgloader against the local scratch DB
  is instant and free; re-running against prod would compete for
  prod's I/O every time

If you're reading this doc looking for the old live-tunnel workflow,
see the git history for the pre-consolidation version.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
