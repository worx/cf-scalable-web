# Migration — prod → sandbox test workflow

**Scope:** copy production Drupal state into a sandbox environment for
testing without touching prod. Structured as four independent flows —
database, codebase, public files, private files — each dumped to S3
independently, restored/transformed independently, and composable
depending on what you're testing.

**Not scope:** production-to-production migrations, live cutover, or
one-way conversions (this repo has a separate playbook for that).

## Directory layout

```
migration/
├── Makefile                       # phase-organized targets, see below
├── README.md                      # this file
├── cloudformation/                # per-phase CFN templates
│   ├── cf-migration-bucket.yaml   # sandbox S3 bucket for dumps + logs
│   ├── cf-migration-secret.yaml   # Secrets Manager entry (prod DB pw)
│   └── cf-migration-jumpbox.yaml  # jumpbox EC2 in prod VPC
├── parameters/
│   ├── migration-bucket-sandbox.json
│   ├── migration-secret.json
│   └── migration-jumpbox.json
├── pgloader/
│   └── zinew.load.tmpl            # pgloader spec (envsubst template)
├── scripts/
│   ├── _common.sh                 # shared logging + confirm helpers
│   ├── _ssm-run-jumpbox.sh        # Mac → jumpbox dispatch via SSM
│   ├── jumpbox/                   # runs ON the prod jumpbox
│   │   ├── dump-mysql.sh
│   │   ├── dump-codebase.sh
│   │   ├── dump-files.sh
│   │   ├── dump-private.sh
│   │   ├── backup-state.sh
│   │   └── restore-state.sh
│   └── deploy-host/               # runs ON the sandbox deploy-host
│       ├── restore-mysql.sh
│       └── run-pgloader.sh
```

## Prerequisites

**AWS profiles**: two profiles configured in `~/.aws/credentials`:
- `ZI-Sandbox` — sandbox account (where the RDS + FSx + compute lives)
- `ZoningInfoAdmin` — prod account (where the jumpbox is deployed)

**On the sandbox deploy-host** (created via top-level Makefile's
`make deploy-deploy-host`):
- pgloader + mariadb-server installed (bootstrap.sh handles this)
- 4 GB swap for pgloader's SBCL heap (bootstrap.sh handles this)
- AWS RDS CA bundle installed (bootstrap.sh handles this — pgloader's
  TLS layer needs it)
- `use-env sandbox` invoked so `/var/www` is mounted from FSx

**In prod** (one-time setup):
- Secrets Manager entry with prod DB password (`make deploy-secret` +
  `make set-secret-password`)
- Jumpbox EC2 deployed with its SSH pubkey pasted into React2's
  `authorized_keys` (`make deploy-jumpbox` + `make jumpbox-pubkey`)

## The migration flow

```
   PROD                    S3 (sandbox)              SANDBOX
   -----                   -----------                --------
   React2 origin ──ssh──►  s3://…/dumps/
   (via jumpbox)              zinew.sql
                              drupal-codebase.tar.gz
                              drupal-files.tar.gz
                              drupal-private.tar.gz

                                     │
                                     ▼
                       ┌── deploy-host operations ──┐
                       │                            │
                       │  restore-mysql.sh          │
                       │    → local MariaDB scratch │
                       │                            │
                       │  run-pgloader.sh           │
                       │    → sandbox RDS Postgres  │
                       │                            │
                       │  (files restore: TODO)     │
                       │    → sandbox FSx           │
                       └────────────────────────────┘
```

### 1. Dump: prod → S3

Runs on the prod jumpbox via `aws ssm send-command` (deploy-host or
Mac orchestrates, jumpbox executes). Each dump is independent —
choose what you need:

| Target | Source | Destination |
|---|---|---|
| `make dump-mysql` | React2's live MySQL via SSH tunnel from jumpbox | `s3://sandbox-migration-kv-worxco/dumps/zinew.sql` |
| `make dump-codebase` | React2's `/var/www/drupal/` | `s3://…/dumps/drupal-codebase.tar.gz` |
| `make dump-files` | React2's `sites/default/files/` | `s3://…/dumps/drupal-files.tar.gz` |
| `make dump-private` | React2's private files dir | `s3://…/dumps/drupal-private.tar.gz` |
| `make dump-all` | all four sequentially | (all four keys above) |

All four are dispatched via `scripts/_ssm-run-jumpbox.sh` which uses
`aws ssm send-command`, then polls until the command finishes. Full
logs land in `s3://…/logs/YYYY-MM-DD/`. Fire-and-forget safe —
disconnecting the operator terminal doesn't kill the jumpbox-side work.

**Dump timing** (from 2026-07 data):
- `dump-mysql`: 5-15 min for a 2.3 GB dump
- `dump-codebase`: 2-5 min for ~700 MB tarball
- `dump-files`: 5-15 min for ~1.8 GB tarball
- `dump-private`: seconds (usually a few hundred bytes)

### 2. Restore DB: S3 → local MariaDB scratch

`make restore-mysql CONFIRMED=yes` — runs on the deploy-host, uses
its IAM instance role for S3 access. Behavior:

1. Fetch `s3://…/dumps/zinew.sql` → `/var/www/mysql/zinew.sql`
   (cached; re-uses local file unless `FORCE_DOWNLOAD=yes`)
2. Sanitize `utf8mb4_0900_ai_ci` → `utf8mb4_unicode_ci` (MariaDB
   compatibility fixup — no-op if the source dump is already
   MariaDB-friendly)
3. Auto-start mariadb (bootstrap installs it disabled to save idle RAM)
4. DROP + CREATE the `zinew` scratch database
5. Create/rotate `worxco@127.0.0.1` with `mysql_native_password`
   (required by pgloader's qmynd MySQL driver)
6. `mysql < dump`
7. Verify table count is non-zero

Env overrides: `MIGRATION_BUCKET DUMP_S3_KEY DUMP_LOCAL_PATH
LOCAL_DB_NAME LOCAL_DB_USER LOCAL_DB_PASS FORCE_DOWNLOAD CONFIRMED DRY_RUN`.

### 3. Transform DB: MariaDB scratch → sandbox RDS Postgres

`make run-pgloader CONFIRMED=yes` — runs on the deploy-host. Behavior:

1. Auto-starts mariadb if not already running
2. Sources `/etc/worxco/envs/sandbox` for RDS connection info
3. Renders `pgloader/zinew.load.tmpl` (envsubst) → `/tmp/zinew.load`
   with `chmod 600` (contains the RDS drupal_user password)
4. Runs `pgloader --dynamic-space-size 4096 --no-ssl-cert-verification /tmp/zinew.load`
5. **Shreds** `/tmp/zinew.load` on exit — password never persists to disk
6. Verifies target schema has tables

The load-file template does:
- `include drop` — every table in the target schema gets dropped and
  recreated (destructive — the sandbox `zinew` schema is fully rebuilt)
- `create tables, create indexes, reset sequences, foreign keys`
- `downcase identifiers` (MySQL is case-insensitive; postgres isn't —
  downcase makes Drupal's PDO queries happy)
- `batch rows = 500, prefetch rows = 500, workers = 2, concurrency = 1`
  (tuned envelope: predictable memory, ~2 hours for 12M rows / 2.3 GB)
- Type casts for MySQL→Postgres quirks: `tinyint(1)→boolean`, zero-date
  sanitization for datetime/date/timestamp

Env overrides: `MIGRATION_BUCKET ENV_FILE TEMPLATE_PATH RENDERED_PATH
PGLOADER_HEAP_MB MIGRATION_DB_NAME CONFIRMED DRY_RUN`.

### 4. Restore files (planned, not yet wired)

`dump-files` and `dump-private` push tarballs to S3, but the sandbox
side doesn't have restore-files / restore-private targets yet. See
"Follow-ups" section below. Without file restore, migrated Drupal
serves broken images (`file_managed` rows point to `public://` paths
that sandbox FSx doesn't have).

## DB-only test migration runbook

This is the runbook validated end-to-end on 2026-07-17. Assumes prod
is stable during the test (nobody actively editing during the ~2-hour
window) and sandbox is the only environment being disturbed.

### Phase 0 — Baseline

```bash
# From Mac: confirm S3 has a dump (dump-mysql already ran)
aws --profile ZI-Sandbox s3 ls s3://sandbox-migration-kv-worxco/dumps/ \
  --human-readable

# On deploy-host (via `make ssm-deploy-host` from Mac):
psql-env sandbox -d drupal -c '\l+ drupal'
psql-env sandbox -d drupal -c '\dn'
psql-env sandbox -d drupal -c \
  "SELECT schemaname, COUNT(*) FROM pg_tables GROUP BY schemaname ORDER BY 1;"
```

Record baseline schema/table counts — informs Phase 1 (what
we're preserving) and Phase 6 (what we compare against).

### Phase 1 — Snapshot: rename current `drupal` DB, create fresh

The rename pattern (see `docs/memory/db-rollback-pattern.md`) is our
rollback safety net — metadata-only, sub-second, application-transparent
once repopulated.

```bash
# On deploy-host:
STAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_DB="drupal_backup_$STAMP"
psql-env sandbox -d postgres <<SQL
GRANT drupal_user TO dbadmin;
ALTER DATABASE drupal OWNER TO dbadmin;
REVOKE CONNECT ON DATABASE drupal FROM PUBLIC, drupal_user;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname='drupal' AND pid<>pg_backend_pid();
ALTER DATABASE drupal RENAME TO $BACKUP_DB;
CREATE DATABASE drupal OWNER drupal_user;
ALTER DATABASE $BACKUP_DB OWNER TO drupal_user;
GRANT CONNECT ON DATABASE drupal TO drupal_user;
GRANT CONNECT ON DATABASE $BACKUP_DB TO drupal_user;
REVOKE drupal_user FROM dbadmin;
\l
SQL
```

The `GRANT/REVOKE drupal_user TO dbadmin` bookends give dbadmin
transient ownership rights for the rename — after the block, the
role graph is exactly as it was pre-run. No permanent state.

At this point sandbox Drupal starts 500'ing (its DB is gone) — that's
expected and continues until Phase 3 finishes.

### Phase 2 — Restore MariaDB scratch (~5 min)

```bash
# On deploy-host (in the same SSM session, or start tmux for
# long-running work — see "Ergonomics" below):
cd ~/projects/cf-scalable-web/migration
sudo make restore-mysql CONFIRMED=yes
```

Verify:
```bash
sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zinew';"
# expect: prod-scale count (2026-07-17 baseline: 413 tables)
```

### Phase 3 — pgloader → sandbox RDS (10-30 min baseline; index build extends this to ~2 hours for 12M rows)

**Run this under tmux** — 2-hour operations vs SSM's ~15 min idle
timeout means an unwrapped run will get killed:

```bash
# On deploy-host in SSM shell:
sudo tmux new -s pgloader
# Inside tmux (you're now root):
cd /home/ubuntu/projects/cf-scalable-web/migration
make run-pgloader CONFIRMED=yes
# Detach: Ctrl+B, then D
# Reattach later: sudo tmux attach -t pgloader
```

Progress lands in `/var/log/worxco-migration/run-pgloader-<UTC>.log`
locally AND `s3://…/logs/YYYY-MM-DD/run-pgloader-<UTC>.log` on exit.
Zero rows in the summary is a red flag; anything nonzero is real data
moved.

Verify:
```bash
psql-env sandbox -d drupal -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zinew';"
# expect: matches MariaDB source count from Phase 2
```

### Phase 4 — Clear caches

```bash
# From Mac:
make clear-drupal-cache ENV=sandbox
```

Wipes Drupal's on-disk compiled container AND TRUNCATEs every
`cache_%` table. Necessary — Valkey/on-disk caches still reference
the sandbox pre-swap DB state.

### Phase 5 — Smoke test

```bash
# From Mac:
make admin-login-url ENV=sandbox
```

Open the URL in a browser. Success criteria:
- Front page returns 200 (broken images / file 404s ARE expected —
  file_managed rows point to `public://` paths that FSx doesn't have)
- Admin UI loads without WSOD
- Site's real content (nodes, custom entities) is present
- Login works
- `drush status` on deploy-host reports the migrated state

### Rollback

Fast, cheap, complete — see `docs/memory/db-rollback-pattern.md`:

```bash
psql-env sandbox -d postgres -c "
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = 'drupal' AND pid <> pg_backend_pid();
"
psql-env sandbox -d postgres -c "DROP DATABASE drupal;"
psql-env sandbox -d postgres -c "ALTER DATABASE $BACKUP_DB RENAME TO drupal;"
make clear-drupal-cache ENV=sandbox
```

Sub-second metadata operations — Drupal is back exactly as it was
before Phase 1 within about 30 seconds of the block.

### Cleanup

Once you've confirmed the test worked and don't need the pre-test state:

```bash
psql-env sandbox -d postgres -c "DROP DATABASE $BACKUP_DB;"
```

Or keep it around for comparison. RDS has a minimum disk size regardless
of DB count, so extra empty-ish DBs don't change billing.

## Ergonomics

### Long-running commands need tmux

SSM Session Manager has ~15-20 min idle timeout. Any operation that
takes longer than that (notably `run-pgloader` with its full index
build) must run under tmux, or the session termination kills the work:

```bash
sudo tmux new -s <name>       # start
# Ctrl+B D                     # detach (session keeps running)
sudo tmux ls                   # list living sessions
sudo tmux attach -t <name>     # reattach
```

**Future automation goal**: Mac-side dispatch targets that use
`aws ssm send-command` instead of interactive Session Manager,
mirroring the jumpbox side's `_ssm-run-jumpbox.sh` pattern. That will
make the whole migration a single `make dispatch-migrate-db` call from
Mac, walk-away safe, no tmux ceremony. See "Follow-ups."

### Log locations

- **Runtime**: `/var/log/worxco-migration/<script>-<UTC>.log` on
  whichever host ran the script
- **Archived**: `s3://<migration-bucket>/logs/YYYY-MM-DD/<script>-<UTC>.log`
  uploaded automatically on script exit (success OR failure)

Every migration script uses `log_init` + `trap log_upload_and_exit` for
this pattern (see `scripts/_common.sh` for the shared helpers).

### Diagnosing what's in the S3 dump

The MySQL dump is human-readable SQL — you can `zcat` (or `cat`) a
subset locally to check what prod had at dump time:

```bash
# Grep for enabled modules in the config table
grep -a "^INSERT INTO \`config\` VALUES" /var/www/mysql/zinew.sql \
  | head -5
```

Rough, but useful when a smoke test surfaces a "why is X missing?"
question.

## Known limitations

- **File / codebase restore not wired** — see follow-ups. Migrated
  Drupal will 404 on images and downloads until this is built.
- **Single-site assumption** — currently the deploy-host has one
  `/var/www/drupal` per env's FSx mount. Multi-site is on the
  roadmap; when it lands, every path in this doc that mentions
  `/var/www/drupal` will need a per-site variant.
- **pgloader public-schema verify was misleading** (fixed in commit
  d9cdb59) — old versions of `run-pgloader.sh` reported "0 tables in
  public schema" post-run even on a successful load. Actual tables
  are in the `zinew` schema (or whatever `MIGRATION_DB_NAME` is set
  to). Current code queries the right schema.
- **`.installed` marker is informational only** (commit 308bdd5) —
  no operation gates on its existence. Refresh with `make create-installed
  ENV=<env>` if the file goes missing or is stale.

## Follow-ups

Tracked separately (project TODO + this session's plan file), listed
here so operators reading this doc know what's coming:

1. **`restore-files` / `restore-private` targets** — untar the S3
   tarballs onto sandbox FSx atomically (with rollback path). Closes
   the "images 404" gap.
2. **`_ssm-run-deploy-host.sh` + Mac-side dispatch targets** — mirror
   of `_ssm-run-jumpbox.sh` for the sandbox side. Removes the tmux
   ceremony requirement and lets a full migration run overnight from
   a laptop that goes to sleep.
3. **`make db-backup` / `make db-restore` wrappers** — encapsulate
   Phase 1's rename dance behind two make targets.
4. **`make migrate-db-all`** — chains `dispatch-restore-mysql` →
   `dispatch-run-pgloader` → `dispatch-clear-drupal-cache` in one
   Mac-side invocation. Depends on #2 and #3.
5. **`docs/MIGRATION.md` rewrite** — that file is pre-consolidation
   stale (references target names that no longer exist). This README
   covers the current flow; the doc-side file gets folded in.
6. **Multi-site path variance** — every `/var/www/drupal` reference
   above becomes `/var/www/<site>/drupal` (or similar) when the
   multi-site rework lands.

## Related docs

- `docs/memory/db-rollback-pattern.md` — why we rename databases
  instead of taking RDS snapshots for test-rollback scenarios
- `docs/memory/structural-checks-over-markers.md` — why `.installed`
  is informational and not a gate
- `docs/DEPLOY-HOST.md` — deploy-host lifecycle, backup/restore of
  operator state
- `docs/OPERATIONS.md` — operational patterns (SSM sessions, use-env,
  etc.)

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
