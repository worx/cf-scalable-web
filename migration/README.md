# Migration — prod → sandbox test workflow

**Scope:** copy production Drupal state into a sandbox environment for
testing without touching prod. Structured as four independent flows —
database, codebase, public files, private files — each dumped to S3
independently. Restore/transform runs on the sandbox side against the
S3-staged artifacts, and composes at three levels:

- **Individual** — one phase at a time (`make restore-mysql`, etc.)
- **DB-only chain** — `make migrate-db-all` (backup → restore-mysql → pgloader → cache-clear)
- **Full chain** — `make migrate-full-all` (migrate-db-all + files + private + second cache-clear)

All chains are walk-away safe: individual phases dispatch via SSM
send-command, which runs on the target host in SSM's own runner — Mac
sleep, terminal close, or session timeout doesn't kill in-flight work.

## Directory layout

```
migration/
├── Makefile                       # phase-organized targets (see help)
├── README.md                      # this file
├── cloudformation/                # per-phase CFN templates
│   ├── cf-migration-bucket.yaml   # sandbox S3 bucket for dumps + logs
│   ├── cf-migration-secret.yaml   # Secrets Manager entry (prod DB pw)
│   └── cf-migration-jumpbox.yaml  # jumpbox EC2 in prod VPC
├── parameters/
├── pgloader/
│   └── zinew.load.tmpl            # pgloader spec (envsubst template)
└── scripts/
    ├── _common.sh                 # shared logging + confirm helpers
    ├── _ssm-run-jumpbox.sh        # Mac → prod jumpbox dispatch
    ├── _ssm-run-deploy-host.sh    # Mac → sandbox deploy-host dispatch
    ├── jumpbox/                   # runs ON the prod jumpbox
    │   ├── dump-mysql.sh
    │   ├── dump-codebase.sh
    │   ├── dump-files.sh
    │   ├── dump-private.sh
    │   ├── backup-state.sh
    │   └── restore-state.sh
    └── deploy-host/               # runs ON the sandbox deploy-host
        ├── restore-mysql.sh
        ├── run-pgloader.sh
        ├── restore-files.sh
        └── restore-private.sh
```

## Prerequisites

**AWS profiles** on the invoking host:
- `ZI-Sandbox` — sandbox account
- `ZoningInfoAdmin` — prod account

**Sandbox side** (top-level Makefile, one-time):
- `make deploy-deploy-host` — provisions the deploy-host with all
  migration tooling baked in (pgloader, mariadb-server disabled, RDS
  CA bundle, session-manager-plugin, 4G swap, etc.)
- **`make install-drupal ENV=sandbox`** — bootstraps Drupal (codebase,
  settings.php, salt in Secrets Manager, `drupal` DB in RDS, secrets).
  **Required before any migrate-*-all run.** Or use `AUTO=yes` on
  migrate-full-all to have it invoked automatically on preflight fail.

**Prod side** (one-time):
- `make deploy-secret` + `make set-secret-password` — Secrets Manager
  entry with prod DB password
- `make deploy-jumpbox` — EC2 in prod VPC (SSM-only, no inbound)
- `make jumpbox-pubkey` — display key to paste into React2's
  `authorized_keys`

## The migration flow

```
   PROD (jumpbox)                   S3 (sandbox bucket)              SANDBOX (deploy-host)
   ------                           -------                          --------
   React2 origin ──ssh──►  s3://…/dumps/                    ┌── deploy-host operations ──┐
   (via jumpbox)              zinew.sql                     │                            │
                              drupal-codebase.tar.gz         │  restore-mysql.sh          │
                              drupal-files.tar.gz            │    → MariaDB scratch DB    │
                              drupal-private.tar.gz          │                            │
                                                             │  run-pgloader.sh           │
                                                             │    → sandbox RDS Postgres  │
                                                             │                            │
                                                             │  restore-files.sh          │
                                                             │    → sandbox FSx (public)  │
                                                             │                            │
                                                             │  restore-private.sh        │
                                                             │    → sandbox FSx (private) │
                                                             └────────────────────────────┘
```

## The three ways to run

### Recommended: `make migrate-full-all` (single command, walk-away)

Runs the entire pipeline as SSM-dispatched phases. Kick from Mac, close
the lid, come back to a fully-migrated sandbox.

```bash
cd migration
make migrate-full-all
# Or, if sandbox Drupal isn't installed yet, let it auto-install:
make migrate-full-all AUTO=yes
```

Runtime: **~2.5 hours** (pgloader is ~1h50m of that; index build
dominates). All phases self-log to `/var/log/worxco-migration/` and
`s3://.../logs/YYYY-MM-DD/`.

**Phases:**
| # | Phase | What it does | Time |
|---|-------|--------------|------|
| -1 | Preflight | Verify sandbox Drupal is installed (structural check on deploy-host) | seconds |
| 0 | Safety DB backup | Rename current `drupal` DB → `drupal_backup_<UTC>` (metadata-only) | seconds |
| 1 | restore-mysql | Fetch prod dump from S3 → load into local MariaDB scratch | ~5-10 min |
| 2 | run-pgloader | MariaDB scratch → sandbox RDS Postgres (12M+ rows, indexes) | ~1h 50m |
| 3 | clear-drupal-cache | Wipe Valkey + on-disk compiled containers | seconds |
| 4 | restore-files | S3 tarball → atomic-swap onto `/var/www/drupal/web/sites/default/files/` | ~5-10 min |
| 5 | restore-private | S3 tarball → atomic-swap onto `/var/www/drupal-private/` (preserving salt.txt) | seconds |
| 6 | clear-drupal-cache | Second cache clear (invalidates image-style caches referencing new files) | seconds |

**Env overrides:**
- `AUTO=yes` — auto-invoke `install-drupal` if preflight fails
- `SKIP_PREFLIGHT=yes` — bypass Phase -1 (only if the check has a false negative)
- `SKIP_BACKUP=yes` — bypass Phase 0 (only if sandbox DB is already scratch)
- `POLL_TIMEOUT=<seconds>` — override per-dispatch poll timeout (default 7200 = 2h)

### DB-only: `make migrate-db-all`

Same as `migrate-full-all` but stops after Phase 3 (cache-clear).
Useful when testing DB schema/config changes without disturbing files.

### Piecewise: `make dispatch-<phase>` (or non-dispatch variants)

Each phase individually:

**Walk-away (SSM-dispatched, run from Mac):**
- `make dispatch-db-backup` — Phase 0
- `make dispatch-restore-mysql` — Phase 1
- `make dispatch-run-pgloader` — Phase 2
- `make dispatch-restore-files` — Phase 4
- `make dispatch-restore-private` — Phase 5

**Interactive (deploy-host-only, no SSM overhead):**
- `make restore-mysql` — Phase 1
- `make run-pgloader` — Phase 2
- `make restore-files` — Phase 4
- `make restore-private` — Phase 5

Same underlying scripts either way. Choose based on run context.

## The four dump capabilities (prod → S3)

All dispatched via `_ssm-run-jumpbox.sh` from Mac to the prod jumpbox.
Each is independent — run what you need, skip what you don't.

| Target | Source (React2) | S3 destination |
|---|---|---|
| `make dump-mysql` | live MySQL via SSH tunnel from jumpbox | `dumps/zinew.sql` |
| `make dump-codebase` | `/var/www/html/zoning_info_platform/` | `dumps/drupal-codebase.tar.gz` |
| `make dump-files` | `sites/default/files/` | `dumps/drupal-files.tar.gz` |
| `make dump-private` | private files dir | `dumps/drupal-private.tar.gz` |
| `make dump-all` | all four sequentially | (all four keys above) |

Cadence: run once per test cycle. Prod dumps aren't part of
`migrate-full-all` — they happen on a separate schedule (before
sandbox tests, or when prod state has meaningfully changed).

## DB safety net — logical rename pattern

Phase 0 uses the "logical-DB rename" pattern (see
`docs/memory/db-rollback-pattern.md`) — metadata-only, sub-second:

```
ALTER DATABASE drupal RENAME TO drupal_backup_<UTC>
CREATE DATABASE drupal OWNER drupal_user
```

Prints the new backup DB name on stdout so the migrate-full-all
recipe can capture it and echo it prominently. To roll back after a
failed test:

```bash
make ssm-deploy-host
make db-restore ENV=sandbox FROM=drupal_backup_20260718_020115
exit
make clear-drupal-cache ENV=sandbox
```

That's the complete rollback — Drupal is back exactly as it was
before Phase 0.

## DB primitive targets (used by chains, also usable standalone)

Deploy-host-only. All support numeric selectors for batch operations.

- `make db-backup ENV=<env>` — snapshot current DB via logical rename
- `make db-restore ENV=<env> FROM=<backup_db>` — rename backup back
- `make list-db-backups ENV=<env>` — numbered listing, newest first
- `make delete-db-backup ENV=<env> SELECT="1 3 5"` — batch delete
  (index numbers from list, or full DB names)

## Ergonomics

### Auto-logging (no operator memory required)

Every dispatch script + every remote script self-logs on both ends:

- **Deploy-host / jumpbox (Linux)**: `/var/log/worxco-migration/<script>-<UTC>.log`
- **Mac (Darwin)**: `/tmp/worxco-migration/<script>-<UTC>.log`
- **S3 archive**: `s3://<migration-bucket>/logs/YYYY-MM-DD/<script>-<UTC>.log`
  (remote scripts upload their log on exit via trap)

You don't need `... 2>&1 | tee logfile` on migrate-full-all. Everything
that matters is captured. Post-mortem after a failed run: `aws s3 ls
s3://<bucket>/logs/$(date -u +%Y-%m-%d)/` and fetch what you need.

### Long-running commands under tmux

If you use the interactive (non-dispatch) targets on deploy-host and
they take longer than SSM Session Manager's ~15 min idle timeout,
wrap in tmux:

```bash
sudo tmux new -s <name>
# Ctrl+B D to detach
sudo tmux attach -t <name>
```

The `dispatch-*` targets don't need this — SSM send-command runs
independently of the calling terminal.

## Known limitations (expected, not bugs)

- **S3-hosted PDF media (flysystem_s3)**: Prod's Drupal references
  files via `s3://YYYY-MM/*.pdf` URIs that resolve against prod's S3
  bucket. Sandbox has its own bucket (`sandbox-drupal-media-kv-worxco`)
  that's empty by default. Migrated Drupal PDF/download links 404 until
  the sandbox bucket is populated. Fix: (a) add flysystem config to
  sandbox settings.php pointing at its own bucket, and optionally (b)
  one-time cross-account sync from prod bucket to sandbox bucket.
- **Public / private file references to non-existent files**: For
  files that never made it into the tarballs (edge cases like symlinks,
  files above the DRUPAL_ROOT dump prefix), Drupal shows broken image
  icons. Rare.
- **Session invalidation**: Every existing sandbox session is
  invalidated on Phase 0's DB rename (that's the whole session table
  going away). Log back in via `make admin-login-url ENV=sandbox`.
- **Site name shows prod's**: `system.site.name` config value is
  migrated. Cosmetic.

## In-progress transitions

### Salt file → Secrets Manager (partially implemented)

`docs/memory/salt-persistence-design.md` details the migration.
Current state:
- Salt is in Secrets Manager (`worxco/<env>/drupal/hash-salt`).
- `refresh-env-config` exports `DRUPAL_HASH_SALT` from Secrets Manager.
- `settings.php` (rewritten by `install-drupal.sh`) prefers env var,
  falls back to file for backward compat.
- `configure-php.sh` exposes `env[DRUPAL_HASH_SALT]` in PHP-FPM pool
  config (needs re-run on existing compute instances).
- `restore-private.sh` still keeps `salt.txt` in `PRESERVE_FROM_BAK`
  default as belt+suspenders.

Follow-up commit drops the file fallbacks once every env is verified
running on the env-var path.

## Follow-ups (open work)

Migration workflow:
- **`restore-codebase`** — dump-codebase exists but no sandbox-side
  restore. Would round out full-parity migration (rare need — sandbox
  usually runs newer or diverged code from prod).
- **S3-hosted media sync** — one-time cross-account sync from prod
  drupal-media bucket to sandbox's, plus flysystem config in
  settings.php. Closes the "PDFs 404" gap for realistic testing.
- **Salt→SSM cleanup** — remove file fallback once transition is
  verified across all envs (see above).
- **`make check-drift`** — warn when local CFN template is newer than
  deployed stack. From `docs/memory/gotchas.md`.
- **Generalize `_ssm-run-deploy-host.sh`** — currently scoped to
  migration/scripts/ only; extending to top-level scripts/ would let
  more dispatchers reuse the pattern.
- **`make refresh-deploy-host-scripts`** — reinstalls copied scripts
  (`refresh-env-config`, `use-env`, etc.) to `/usr/local/sbin/`
  without a full bootstrap re-run.

## Related docs

- `docs/MIGRATION.md` — cross-account overview / when-to-migrate
- `docs/memory/db-rollback-pattern.md` — why we rename databases
  instead of RDS snapshots for test rollback
- `docs/memory/structural-checks-over-markers.md` — why `.installed`
  is informational and not a gate
- `docs/memory/salt-persistence-design.md` — hash_salt storage design
- `docs/memory/gotchas.md` — cross-cutting operational lessons
- `docs/DEPLOY-HOST.md` — deploy-host lifecycle
- `docs/OPERATIONS.md` — day-to-day operational patterns

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
