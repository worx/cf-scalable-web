---
name: DB rollback pattern — logical-DB rename, not RDS snapshot
description: Preferred rollback strategy for destructive PostgreSQL operations in test workflows — rename current DB, create fresh, operate, drop/rename back. Metadata-only, sub-second, application-transparent.
type: project
created: 2026-07-17
---
# DB rollback pattern — logical-DB rename

## TL;DR

For **destructive database operations that need a rollback** (e.g., loading
prod data into sandbox via pgloader, or any other DDL/DML that could ruin
the current state), reach for a **logical-DB rename at the engine level**,
not `aws rds create-db-snapshot`.

```sql
-- As RDS master (dbadmin), against maintenance DB `postgres`:
ALTER DATABASE drupal RENAME TO drupal_backup_<STAMP>;
CREATE DATABASE drupal OWNER drupal_user;
-- do the destructive thing (pgloader, drush site:install, etc.)
-- against the fresh `drupal` DB

-- Rollback if needed:
DROP DATABASE drupal;
ALTER DATABASE drupal_backup_<STAMP> RENAME TO drupal;
```

Rename is metadata-only. Sub-second. No I/O. No new RDS instance. No
endpoint change. No `settings.php` edit. Application (Drupal) references
the database by name — once the new DB has the tables Drupal expects,
it just works again.

## Why this over `aws rds create-db-snapshot`

The alternative — take a snapshot before the destructive op, restore
from snapshot if things go wrong — has two costs the rename pattern
avoids:

1. **Restore-from-snapshot creates a NEW RDS instance.** Not an
   overwrite. To use it, you have to:
   - Wait for the new instance to come available (~10-30 min)
   - Update the SSM parameter `/{env}/rds/endpoint` to point at it
   - Run `refresh-env-config` on the deploy-host
   - Roll compute so PHP-FPM picks up the new endpoint
   - Delete the old broken instance later
   Total: an hour of orchestration plus real dollars for the parallel
   instance. Kurt: "way too much overhead."

2. **Snapshot itself takes minutes** and only guards against failure
   modes that need instance-level rollback (WAL corruption, engine
   version issues). For the common case — pgloader wrote broken data,
   or an install script trashed things — you just want the old DB back.
   Rename gives that in a keystroke.

## Constraints and gotchas

**Active connections block `ALTER DATABASE ... RENAME`.** You have to
kick them off first:

```sql
REVOKE CONNECT ON DATABASE drupal FROM PUBLIC, drupal_user;
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = 'drupal' AND pid <> pg_backend_pid();
```

The app (Drupal via PHP-FPM) will 500 for the window between the rename
and repopulation. **For sandbox this is fine** — Kurt is the only user
and it's a test. **For production or shared sandbox** — combine with
`drush sset system.maintenance_mode 1` first so users see a friendly
maintenance page during the window, and put an app-level lock in place
so no one lands on it mid-transaction.

**Restore the CONNECT grant after** — otherwise even the newly-created
DB will refuse connections until you re-grant it:
```sql
GRANT CONNECT ON DATABASE drupal TO drupal_user;
GRANT CONNECT ON DATABASE drupal_backup_<STAMP> TO drupal_user;
```

**Schema ownership carries over.** The renamed DB keeps all its schemas
(`public`, `zinew`, etc.) and their tables intact. When you create the
fresh DB, it only has an empty `public` schema until you populate it.
For our pgloader flow, that's exactly what we want — pgloader creates
its own schema matching the source MySQL DB name.

**Extension name is intentional.** `drupal_backup_YYYYMMDD-HHMMSS` (UTC)
sorts chronologically, self-documents when it was taken, and doesn't
collide with anything Drupal-generated. Keep the backup at least until
smoke-testing the new state; keep it longer if you want to `psql` into
it later for comparison.

## When NOT to use this pattern

- **Corruption at the WAL / storage layer.** If the database itself is
  physically damaged (bad blocks, replication drift, storage-level
  errors), the rename target inherits the damage. Need PITR / snapshot
  restore for that.
- **Multiple databases must move together atomically.** Rename is
  per-DB. If your rollback needs to preserve cross-database consistency,
  snapshot the whole instance.
- **Engine version upgrades.** Rename doesn't help across major-version
  changes; snapshot + restore-with-upgrade is the tool for that.

## Related

- `migration/pgloader/zinew.load.tmpl` — the pgloader spec this pattern
  guards against
- `migration/scripts/deploy-host/run-pgloader.sh` — the wrapper that
  invokes pgloader against the `drupal` DB
- `scripts/deploy-host/psql-env` — the CLI shortcut that gets you an
  RDS-master psql shell (needed for the rename dance)
- `cloudformation/cf-database.yaml` — sets `BackupRetentionDays=1` for
  sandbox (thin PITR window; another reason the rename pattern is the
  primary rollback story for sandbox)

## Future ergonomics

Two make targets would collapse this to one-liners:

```
make db-backup ENV=sandbox           # ALTER DATABASE drupal RENAME TO drupal_backup_<STAMP>; CREATE fresh
make db-restore ENV=sandbox FROM=<name>  # DROP drupal; ALTER backup RENAME TO drupal
```

Not built yet. When we do, keep them scoped to the `postgres` maintenance
DB for the ALTER/DROP/CREATE, and require `CONFIRMED=yes` on the restore
side.
