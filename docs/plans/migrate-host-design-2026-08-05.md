---
name: migrate-host — Ephemeral Migration Instance Design
description: Comprehensive design for a new on-demand EC2 instance that moves MariaDB + pgloader off the deploy-host, enabling proper tuning for a 20-30 min migration-time reduction. For solo review + markup before implementation begins.
audience: kurt-solo-review
status: DRAFT — awaiting review
date: 2026-08-05
supersedes: none (net-new addition; adjacent to cf-deploy-host)
tag-baseline: v0.5.0-migration-ready
---

# migrate-host — Ephemeral Migration Instance Design

## §1 — Executive Summary

**What this is.** A design document for a new CloudFormation-managed
EC2 instance called the "migrate-host" that gets launched on-demand
at the start of every migration, does the heavy MariaDB + pgloader
work, and gets destroyed at the end. Same review-then-implement
pattern we used for the multi-tenant refactor at
`docs/plans/multi-tenant-refactor-review-2026-07-31.md`.

**Why.** Today's migration flow runs MariaDB (as staging DB) and
pgloader (MySQL → PostgreSQL) on the deploy-host itself. Deploy-host
is a `t4g.small` (2 vCPU, 2 GiB RAM, 4 GiB swap) — sized specifically
to give pgloader's SBCL heap enough room to breathe. Even so, both
subsystems are tuned WAY down from their defaults just to fit: MariaDB
runs on distro defaults (128 MiB buffer pool), pgloader runs with
`workers=2, concurrency=1, batch/prefetch=500` (defaults are 4 + higher
+ 25000/1000). The result is a ~10-15 min MySQL restore + ~30 min
pgloader run — dominated by IOPS-capped InnoDB flushing and
strictly-serial pgloader table imports.

**MVP goal.** Move MariaDB + pgloader onto a `r7g.xlarge` (4 vCPU, 32
GiB, Graviton 3) that gets provisioned fresh, tuned aggressively for
bulk-load, used for 30-60 min, then torn down. Expected wall-time
delta: 25-30 min saved on `migrate-db-all` (matching Kurt's stated goal).

**Later** (design does not preclude): pigz-parallel tar extraction for
restore-files/codebase/private (marginal win — FSx-I/O-bound), separate
EBS data volume for `/var/lib/mysql`, io2 storage tier, multi-env
parallel migrations, spot instance pricing for even cheaper ephemeral runs.

**Key facts to have in mind while reading:**

- Deploy-host stays but shrinks. Phase 5 of rollout drops MariaDB +
  pgloader from its bootstrap, drops the 4 GiB swap block from its
  CFN template, and defaults its instance type from `t4g.small` to
  `t4g.micro` (halves its idle cost).
- The migrate-host is EPHEMERAL — one hour of existence per run at
  ~$0.35 all-in (instance + storage). Nightly EventBridge backup
  captures operator state (SSH keys, .env, bash history) so
  "poke around interactively" days don't lose work.
- All decisions in §4 are locked with Kurt via AskUserQuestion in the
  2026-08-05 planning session — no open questions for MVP scope.

---

## §2 — What Kurt Actually Wants (from 2026-08-05 conversation)

Kurt's exact requirements, restated for clarity:

1. **New CFN-managed instance**, launched on-demand for migration
   work, destroyed after. ~1 hour of existence per run.
   **Provisioning approach: bootstrap.sh (parallel to deploy-host's
   pattern), NOT a pre-built AMI.** Trade-off Kurt weighed and
   accepted: bootstrap.sh takes 3-4 min at first-boot vs ~90 sec
   for a pre-baked AMI, but bootstrap.sh is far easier to iterate
   on during the tuning phases. See §12 for the "Phase 6: bake AMI"
   post-MVP optimization once the design settles.
2. **Graviton — NOT the t4g family**. At least 4 vCPUs, 16 GiB RAM.
3. **MariaDB moves off deploy-host** onto the new host.
4. **pgloader moves off deploy-host** onto the new host.
5. **pgloader tuning dialed UP** — rough proposed range: 8 threads,
   batch 1000-5000. (Actual locked values in §4 land at
   `workers=4, concurrency=4, batch/prefetch=5000` after design math.)
6. **Full backup/restore parity with deploy-host** — bash history,
   `/etc/worxco/`, SSH keys, `.env`, `.zsh_history`, etc. — even
   though ephemeral, for the "poke around interactively" case.
7. **Lifecycle**: deploy → run → destroy each time by default. Cost
   of the instance is negligible per run.
8. **After migrate-host takes over**: deploy-host can shrink from
   `t4g.small` back to `t4g.micro` since MariaDB + pgloader are
   the reason it was upped.
9. **Goal**: shave 20-30 min off total migration time (currently ~1h35m
   end-to-end for destroy-all + deploy-all + migrate-full-all + smoke).
10. **Access pattern**: SSM Session Manager only (no SSH). Deploy-host
    / operator's Mac talks to migrate-host via `aws ssm send-command`
    over AWS APIs — no VPC-level network path required. This is
    critical to §7.3's design simplification.

---

## §3 — Current State of the Codebase (audit 2026-08-05)

Two Explore agents mapped the current architecture during the 2026-08-05
planning session. Summarized here; see Appendix A + B for file:line
detail.

### 3.1 Deploy-host build (from Explore agent 1)

**CFN template**: `cloudformation/cf-deploy-host.yaml`.
- `InstanceType` default `t4g.small` (2 vCPU, 2 GiB), Ubuntu 24.04
  arm64, in **AWS default VPC** (172.31.0.0/16). Comment on line 12
  explicitly notes it "survives project VPC teardowns."
- Root EBS: 20 GiB gp3 encrypted, single volume.
- Swap: 4 GiB `/swapfile`, `swappiness=10`. UserData comment
  (cf-deploy-host.yaml:177-182) says the 4 GiB was sized specifically
  "for pgloader migrations (SBCL --dynamic-space-size 4096) plus
  headroom … with tuned pgloader (batch rows = 250, workers = 2,
  concurrency = 1) fits comfortably."
- IAM: `AmazonSSMManagedInstanceCore` + `AdministratorAccess` (broad).
- SG: empty ingress (SSM Session Manager only), default egress open.
- SSM Session Manager document `SSM-SessionManagerRunShell` is
  ACCOUNT-WIDE and owned by cf-deploy-host — the migrate-host stack
  MUST NOT create a duplicate.

**Peering**: `cloudformation/cf-deploy-peering.yaml` per-env — VPC
peering default⇄project + routes both ways + SG-to-SG ingress rules
on project SGs (FSx 2049 + 111, RDS 5432, Valkey 6379) sourced from
the deploy-host SG.

**Bootstrap**: `scripts/deploy-host/bootstrap.sh` (692 lines).
Installs: `mariadb-server mariadb-client pgloader postgresql-client`
(then `systemctl disable --now mariadb` because deploy-host only
uses MariaDB on-demand for migrations), plus `php8.3-*`, Node 20,
Composer, Drush, cfn-lint, tmux/zsh/htop, RDS CA bundle. Writes
`/etc/worxco/deploy-host-marker` which Makefile targets grep for
to distinguish deploy-host from other hosts.

**Backup pattern**: `scripts/deploy-host/backup-state.sh` +
`scripts/deploy-host/restore-state.sh`. `BACKUP_PATHS[]` captures
SSH keys, `.env`, `bin/`, `.aws/config` (NOT credentials), current-env
marker, `.bashrc/.profile/.zsh_history/.mysql_history`, htop config.
Tar → S3 latest + dated archive. Nightly EventBridge Scheduler
(`0 2 * * ? * America/Chicago`) → SSM SendCommand → backup-state.sh
fetched from S3. Auto-restore on first boot from S3 latest tarball
via UserData block.

### 3.2 MariaDB + pgloader current state (from Explore agent 2)

**MariaDB installation** (bootstrap.sh:397-418):
- Distro package `mariadb-server` on Ubuntu 24.04 arm64.
- **ZERO custom my.cnf, mysqld override, or drop-in config** anywhere
  in the repo. Runs on pure distro defaults.
- `innodb_buffer_pool_size` = ~128 MiB (default).
- No log tuning, no tmp table tuning, no flush tuning, no bulk-import
  mode.
- Data dir `/var/lib/mysql` on the 20 GiB root gp3 EBS
  (**3000 IOPS baseline = today's real bottleneck**).
- Service `systemctl disable --now mariadb` immediately after install
  (deploy-host uses MariaDB only on-demand for migration; costs
  ~100 MiB RAM idling).

**restore-mysql.sh** (`migration/scripts/deploy-host/restore-mysql.sh`):
- Line 283: `mysql -h 127.0.0.1 -u $LOCAL_DB_USER -p$LOCAL_DB_PASS
  $LOCAL_DB_NAME < $DUMP_LOCAL_PATH`
- **No flags** — no `--max-allowed-packet`, no unique-check disable,
  no FK-check disable, no autocommit disable.
- Sed sanitize step (:205-219): `sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'`
  — single-pass over the multi-hundred-MiB dump (CPU-bound).
- Bottleneck today: (a) InnoDB flushing to 3000-IOPS-capped root EBS,
  (b) tiny 128 MiB buffer pool causes constant page evictions.

**pgloader**:
- Template: `migration/pgloader/zinew.load.tmpl:56-65` — hardcoded
  values (not env-driven):
  - `batch rows = 500`
  - `prefetch rows = 500`
  - `workers = 2` (default is 4)
  - `concurrency = 1` (default higher; strictly one table at a time)
  - No `batch size = N MB` set, no `max parallel create index` set.
- SBCL heap: `PGLOADER_HEAP_MB=4096` (`run-pgloader.sh:98`), passed
  as `--dynamic-space-size` CLI flag at run-pgloader.sh:296-298.
- Historical progression documented in template comments + commit
  `a3d10e4`: pgloader defaults (~25000/1000) → OOM on original 2 GiB
  swap → 250 (safe) → 500 (current). Kurt's memory
  "1000→250, threads 4→2" maps to exactly these knobs.

**Migration Makefile phases** (`migration/Makefile`):
- `migrate-db-all` phases: -2 refresh-env, -1 preflight, 0 db-backup,
  **1 dispatch-restore-mysql**, **2 dispatch-run-pgloader**,
  3 clear-drupal-cache.
- `migrate-full-all` wraps + sync-s3-media + restore-files/private/codebase
  + clear-cache + restart-php-fpm.
- `_ssm-run-deploy-host.sh:820` comment: "2-hour default POLL_TIMEOUT
  matches the observed pgloader wall time for a full 12M-row load."

### 3.3 Observed migration timing (2026-08-04 successful cycle)

- restore-mysql: 10-15 min
- run-pgloader: ~30 min (observed by Kurt; Makefile documents "up to
  2 hours" ceiling for the largest case)
- Total migrate-db-all: ~60-90 min
- Total end-to-end (destroy → deploy → migrate → smoke): 1h35m

### 3.4 Where more CPU/RAM helps (from Explore agent 2)

- **MariaDB restore**: RAM helps most. Bigger `innodb_buffer_pool_size`
  dramatically reduces flushing pressure. CPU less relevant (single-
  threaded `mysql` client). Provisioned IOPS also helps until the
  buffer pool is big enough to hold the working set.
- **pgloader**: BOTH help. RAM feeds SBCL heap + batch/prefetch buffer.
  CPU enables `workers` + `concurrency` parallelism.
  **`concurrency=4` is the single biggest wall-time win** — 4 tables
  loaded in parallel vs. today's strictly-serial one-at-a-time.
- Other migration steps: `tar xzf` in restore-files/codebase/private is
  single-threaded gzip. `pigz` swap could parallelize but the workload
  is FSx-I/O-bound anyway — marginal win. `sync-s3-media` runs on the
  prod jumpbox (cross-account), NOT a migrate-host candidate.

---

## §4 — Design Decisions Locked (2026-08-05 session)

Every decision below was explicitly confirmed with Kurt via
AskUserQuestion in the 2026-08-05 planning session.

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 4.1 | Instance family | `r7g.xlarge` (4 vCPU, 32 GiB, Graviton 3, ~$0.214/hr) | Concurrent MariaDB (8 GiB buffer pool) + pgloader (10 GiB SBCL heap) both want RAM. m7g.xlarge (16 GiB) forces tuning down and defeats the purpose. Extra $0.05/hr over m7g = ~$0.05 per ~1-hr run. Future-proofs for 20 GiB client DBs. |
| 4.2 | Root EBS | 40 GiB gp3, 10000 IOPS, 500 MB/s throughput | Directly attacks the current InnoDB flush bottleneck. 3.3× baseline IOPS + 4× throughput. Middle ground; skips the last $0.08/run for full-max (16000/1000). ~$0.06/run above baseline. |
| 4.3 | Swap | 0 (none) | 32 GiB RAM + our tuning ceilings never approach 24 GiB used. Swap would only mask an OOM by turning it into thrash. |
| 4.4 | Lifecycle default | `MIGRATE_HOST_LIFECYCLE=ephemeral` (deploy → run → destroy every `migrate-db-all`) | Matches Kurt's stated intent. Cost per run ~$0.35 (instance + storage for ~1 hour). `keep` and `none` available as env-var overrides. |
| 4.5 | Backup parity | Full deploy-host style: dedicated S3 bucket, backup-state.sh + restore-state.sh, nightly EventBridge Scheduler, auto-restore on first boot from S3 latest tarball | Kurt explicit: "we even want to have a backup restore function for the migrate host, like we do for the deploy host" — for the "poke around interactively" case where bash history + SSH keys + operator dotfiles are painful to lose. |
| 4.6 | **Network placement** (revised 2026-08-05 per Kurt's review) | **Migrate-host lives IN the project VPC** (private subnet), NOT in the default VPC alongside deploy-host. This eliminates ALL peering complexity for the migrate-host. Deploy-host stays in default VPC (still peers to project VPC per today). SSM SendCommand between deploy-host and migrate-host goes over AWS APIs — no VPC-to-VPC network path needed. |
| 4.7 | **SG ingress rules** (revised) | ONE ingress rule needed: RDS SG accepts 5432 from migrate-host SG. No FSx access needed (dump staged locally on migrate-host's 40 GiB gp3, not `/var/www/mysql/` on FSx). No Valkey access needed (Drupal caching is not part of migration). Ingress rule lives inline in `cf-migrate-host.yaml` for lifecycle atomicity. |
| 4.8 | SSMSessionPreferences | NOT duplicated | Account-wide `SSM-SessionManagerRunShell` document already owned by cf-deploy-host. Two stacks creating same-named document = collision. |
| 4.9 | MariaDB service state on migrate-host | `systemctl enable --now mariadb` (opposite of deploy-host's `disable --now`) | This box's whole purpose is to run MariaDB. Different from deploy-host where MariaDB is on-demand-only. |
| 4.10 | Marker file | `/etc/worxco/migrate-host-marker` (parallel to deploy-host's marker) | Guards for restore-mysql.sh wrap code — only apply bulk-load flags when running on migrate-host, not on legacy deploy-host during rollout. |
| 4.11 | **Dump staging path** (revised 2026-08-05 per Kurt's review) | `/var/tmp/migration/zinew.sql` (local disk on migrate-host's 40 GiB gp3), NOT `/var/www/mysql/zinew.sql` (FSx). Kurt caught this — deploy-host used FSx because its 20 GiB root couldn't hold multi-GiB dumps; migrate-host's 40 GiB high-IOPS gp3 has plenty of room. Bonus: removes FSx dependency + `nfs-common` package + `use-env sandbox` boot step. |

---

## §5 — Instance Spec

### 5.1 EC2 instance

- **Type**: `r7g.xlarge`
- **AMI**: `ami-*` resolved from SSM public parameter
  `/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id`
  (same as deploy-host — arm64 correct for Graviton).
- **Placement**: **Project VPC, private subnet** (revised per Kurt's
  review 2026-08-05). Unlike deploy-host (which lives in the default
  VPC to survive project teardowns), the migrate-host is ephemeral —
  it doesn't need to outlive the project VPC. Living IN the project
  VPC gives direct SG-based access to RDS with zero peering complexity.
  If someone runs `destroy-all` while a migrate-host is up (unusual),
  they need to `destroy-migrate-host` first — mirroring how any
  workload compute stack works today.
- **Access**: SSM Session Manager only. No SSH keypair. No inbound.
- **Cost math**: $0.214/hr × 1 hour = ~$0.21/run for the instance
  itself; plus ~$0.06/run for the provisioned-IOPS EBS; plus ~$0.08/run
  for the 40 GiB gp3 base storage prorated to one hour ≈ negligible.
  All-in per ephemeral run: **~$0.35**.

### 5.2 Root EBS

```yaml
BlockDeviceMappings:
  - DeviceName: /dev/sda1
    Ebs:
      VolumeType: gp3
      VolumeSize: 40
      Iops: 10000
      Throughput: 500
      Encrypted: true
```

**Sizing math** (revised 2026-08-05 for local dump staging): ~5 GiB
OS + ~3 GiB staged dump at `/var/tmp/migration/zinew.sql` (local
disk now, not FSx — see §4.11) + ~6 GiB imported `/var/lib/mysql`
+ working temp ≈ 15 GiB peak. 40 GiB gives 25 GiB slack for future
bigger client DBs.

**Why provisioned IOPS matters here**: bulk-load `mysql < dump.sql`
today stalls on 3000-IOPS-capped root EBS. Bumping to 10000 IOPS +
500 MB/s throughput eliminates this bottleneck for both InnoDB tablespace
writes and dump-file sequential reads.

### 5.3 Swap

**None.** Deploy-host currently has 4 GiB `/swapfile` — that's a
concession to running pgloader's 4 GiB SBCL heap on a 2 GiB physical
RAM machine. The migrate-host at 32 GiB has zero need. Swap in this
context would only convert an OOM (hard fail) into unbounded thrashing
(slow fail) — worse UX.

---

## §6 — Tuning Targets

### 6.1 MariaDB (new drop-in file)

Path: `/etc/mysql/mariadb.conf.d/99-migrate-host.cnf` (written by
`scripts/migrate-host/bootstrap.sh`).

```ini
[mysqld]
# Sized for r7g.xlarge (32 GiB).
# Leaves ~10 GiB for pgloader SBCL + ~8 GiB slack.
innodb_buffer_pool_size          = 8G
innodb_buffer_pool_instances     = 4
innodb_log_file_size             = 1G
innodb_log_buffer_size           = 64M
innodb_flush_log_at_trx_commit   = 0    # bulk-load; flush once/sec
innodb_doublewrite               = 0    # throwaway DB, skip DW
innodb_flush_method              = O_DIRECT
innodb_io_capacity               = 2000
innodb_io_capacity_max           = 4000
innodb_buffer_pool_dump_at_shutdown = 0
innodb_buffer_pool_load_at_startup  = 0
sync_binlog                      = 0
skip_log_bin                          # no binlog at all
max_allowed_packet               = 512M
performance_schema               = OFF  # save ~500 MB for buffer pool
```

**Rationale per group**:

- `innodb_buffer_pool_size = 8G` (default ~128 MiB): the zinew DB is
  ~2.5-4 GiB imported. 8 GiB comfortably holds the whole working set
  in RAM, eliminating the flush-and-reread cycle that dominates
  today's IOPS-capped restore.
- `innodb_log_file_size = 1G` (default 96 MiB): far fewer checkpoint
  stalls during the multi-GiB import. At 96 MiB defaults the log
  rotates constantly during a bulk import; at 1 GiB it barely does.
- `flush_log_at_trx_commit = 0` + `sync_binlog = 0` + `skip_log_bin` +
  `doublewrite = 0`: **standard "bulk-load; durability doesn't matter"
  recipe**. Turns synchronous IOPS-bound writes into async ones. Safe
  because the migrate-host is a throwaway — if it crashes mid-restore,
  we destroy and rerun. No production data at risk.
- `O_DIRECT` + big buffer pool: avoids double-caching (OS page cache
  + InnoDB cache).
- `performance_schema = OFF`: saves ~500 MiB RAM. We're not
  monitoring per-query stats during a bulk import.

### 6.2 `restore-mysql.sh` — dump staging path + session-flag wrap

**Dump staging path change** (revised 2026-08-05 per Kurt's review):
the current `DUMP_LOCAL_PATH="/var/www/mysql/zinew.sql"` defaults to
FSx because deploy-host's 20 GiB root can't hold a multi-GiB dump.
On migrate-host, override to `/var/tmp/migration/zinew.sql` (local
40 GiB gp3 with plenty of room). Simplest way: honor the existing
`DUMP_LOCAL_PATH` env var, and set it explicitly in the migrate-host
dispatch:

```bash
DUMP_LOCAL_PATH="/var/tmp/migration/zinew.sql" \
HOST_STACK=cf-migrate-host \
make dispatch-restore-mysql
```

Or bake into the dispatch wrapper: when `HOST_STACK=cf-migrate-host`,
default `DUMP_LOCAL_PATH` to `/var/tmp/migration/zinew.sql`. Same
effect, less operator boilerplate.

**Session-flag wrap** applied around the `mysql < dump.sql` call at
line 283. Guarded by marker file so the wrap only fires on the
migrate-host (deploy-host falls through to legacy behavior during
Phase 1-4 rollout).

```bash
if [ -f /etc/worxco/migrate-host-marker ]; then
  {
    echo "SET SESSION FOREIGN_KEY_CHECKS = 0;"
    echo "SET SESSION UNIQUE_CHECKS      = 0;"
    echo "SET SESSION AUTOCOMMIT         = 0;"
    echo "SET SESSION SQL_LOG_BIN        = 0;"
    cat "$DUMP_LOCAL_PATH"
    echo "COMMIT;"
  } | mysql -h 127.0.0.1 -u "$LOCAL_DB_USER" \
      -p"$LOCAL_DB_PASS" "$LOCAL_DB_NAME"
else
  # Legacy deploy-host path
  mysql -h 127.0.0.1 -u "$LOCAL_DB_USER" \
    -p"$LOCAL_DB_PASS" "$LOCAL_DB_NAME" < "$DUMP_LOCAL_PATH"
fi
```

**Rationale per flag**:

- `FOREIGN_KEY_CHECKS=0`: skip FK validation on every insert. Dump
  statement order can temporarily violate FKs; final state is consistent.
- `UNIQUE_CHECKS=0`: skip unique-index probes. Dump is unique by
  construction; probes are wasted work.
- `AUTOCOMMIT=0` + trailing `COMMIT`: one transaction for the whole
  import. InnoDB doesn't fsync per-statement.
- `SQL_LOG_BIN=0`: belt-and-suspenders with server-level `skip_log_bin`.

### 6.3 pgloader (edits to `migration/pgloader/zinew.load.tmpl` WITH block)

| Knob | Old | New | Why |
|---|---:|---:|---|
| `batch rows` | 500 | 5000 | 10× fewer INSERT round-trips to RDS |
| `batch size` | (unset) | 100 MB | Hard cap on per-batch RAM — protects against a wide-row table blowing past the row-count estimate |
| `prefetch rows` | 500 | 5000 | Match batch so MariaDB reads don't stall behind Postgres writes |
| `workers` | 2 | 4 | Pgloader's own default; matches 4-vCPU host |
| `concurrency` | 1 | 4 | **Biggest wall-time win** — 4 tables imported in parallel vs. strictly serial today |
| `max parallel create index` | (unset) | 4 | Parallel index builds after loads — matters for large tables |
| `PGLOADER_HEAP_MB` (run-pgloader.sh env) | 4096 | 10240 | SBCL heap: 4 concurrent tables × ~150-250 MiB in-flight + working set. 10 GiB = 5× headroom |

**Which knob matters most**: `concurrency` — by a mile. Everything
else is a linear speedup on top of that. If MVP runs prove unstable,
back off in this order: (1) drop concurrency to 2, (2) shrink batch
size to 50 MB, (3) drop workers to 2.

### 6.4 Expected wall-time impact

- restore-mysql: 10-15 min → **3-5 min** (8 GiB buffer pool + bulk
  flags + 10000 IOPS storage)
- pgloader: 30 min → **8-12 min** (concurrency=4 is the biggest win;
  workers=4 + heap headroom compound)
- **Total migrate-db-all savings: 25-30 min** (matching Kurt's goal)

---

## §7 — CFN Structure

### 7.1 Files to create

| File | Purpose |
|---|---|
| `cloudformation/cf-migrate-host.yaml` | Main stack: EC2 + IAM + SG + peering SG ingress + EventBridge nightly-backup scheduler + backup bucket reference |
| `cloudformation/cf-migrate-host-backups.yaml` | S3 bucket for state backups. Near-verbatim clone of `cf-deploy-host-backups.yaml` |
| `cloudformation/parameters/migrate-host.json` | InstanceType, backups bucket name, env name |
| `cloudformation/parameters/migrate-host-backups.json` | Env name, bucket suffix |

### 7.2 Deltas from `cf-deploy-host.yaml`

- `InstanceType` default `r7g.xlarge`. `AllowedValues` extended to
  `[m7g.xlarge, m7g.2xlarge, r7g.xlarge, r7g.2xlarge, c7g.xlarge,
  c7g.2xlarge]` (all Graviton 3, xlarge+).
- `BlockDeviceMappings`: 40 GiB with `Iops: 10000, Throughput: 500`.
- **UserData**: bootstrap path → `scripts/migrate-host/bootstrap.sh`.
  **Remove** the `fallocate -l 4G /swapfile` block. Marker file →
  `/etc/worxco/migrate-host-marker`. Auto-restore S3 key →
  `config/migrate-host-latest.tar.gz`.
- **`SSMSessionPreferences`**: **REMOVE this resource entirely**.
  The `SSM-SessionManagerRunShell` document is account-wide and already
  owned by cf-deploy-host. Two stacks with the same-named document
  would collide on deploy.
- **`NightlyBackupSchedule`**: same shape as deploy-host's, but
  retarget the migrate-host paths. Consider `State: ENABLED` — even
  though the box is usually torn down, the schedule fires only if
  the instance exists (SSM SendCommand fails silently if no target),
  so nightly capture happens automatically on "keep" days.

### 7.3 Network access — trivially simple (project-VPC placement)

**Revised 2026-08-05 per Kurt's review**: migrate-host lives IN the
project VPC (§5.1), so there is NO peering complexity for the
migrate-host at all. Deploy-host's own peering stack
(`cf-deploy-peering.yaml`) is unchanged — that's about deploy-host's
access from the default VPC to the project VPC, which is unrelated
to migrate-host now.

**What migrate-host actually needs:**

- **RDS access (only)**: outbound 5432 to the RDS SG. Inline SG
  ingress rule in `cf-migrate-host.yaml`:

```yaml
RDSIngressFromMigrateHost:
  Type: AWS::EC2::SecurityGroupIngress
  Properties:
    GroupId: !ImportValue
      Fn::Sub: '${EnvironmentName}-rds-sg-id'
    IpProtocol: tcp
    FromPort: 5432
    ToPort: 5432
    SourceSecurityGroupId: !Ref MigrateHostSecurityGroup
    Description: Postgres from migrate-host (pgloader target)
```

- **AWS-service access**: S3 (fetch dump + backup state), Secrets
  Manager (DB passwords), SSM (agent registration + SendCommand
  target). All via **VPC endpoints already provisioned** by the
  project VPC stack for the compute fleets — migrate-host inherits
  them automatically by being in the same VPC.

**What migrate-host does NOT need:**

- **FSx access** — dump now stages on local disk (§4.11), not
  `/var/www/mysql/`. No NFS mount, no `nfs-common` package.
- **Valkey access** — Drupal caching isn't part of migration.
- **VPC peering** — SSM SendCommand between deploy-host and
  migrate-host goes over AWS APIs, not the VPC network.
- **Public IP** — outbound is via VPC endpoints; there's nothing
  external to reach.

**Why inline the SG ingress rule** (same argument as before, still
holds): destroying the migrate-host stack removes the SG. If the
ingress rule referencing that SG lived in a separate peering-like
stack, the destroy would fail. Inline = lifecycle-atomic.

### 7.4 Backup bucket stack

Clone `cf-deploy-host-backups.yaml` verbatim. Rename bucket to
`sandbox-migrate-host-backups-kv-worxco`. Same lifecycle rules
(logs 30d, dated archives 90d, latest tarball never expires).

---

## §8 — Bootstrap Script

Path: `scripts/migrate-host/bootstrap.sh`. Copy `scripts/deploy-host/bootstrap.sh`
as the starting point, then:

**DROP** (not needed on migrate-host):
- cfn-lint venv setup (this box isn't a CFN development environment)
- Node 20 LTS + `@anthropic-ai/claude-code` (no Claude Code here)
- PHP 8.3 + all `php83-*` extensions
- Composer
- Drush (global for ubuntu user)
- install-drupal-local setup

**KEEP** (operator ergonomics + tools needed by migration scripts):
- `apt install htop tmux vim zsh tree jq pv plocate` (interactive fluency)
- Editor env vars (`EDITOR/VISUAL=vim`, `AWS_PAGER=""`, `AWS_CLI_AUTO_PROMPT=off`)
- tmux + zsh + RPROMPT config (matches deploy-host UX exactly)
- `chsh -s /bin/zsh ubuntu`
- `.aws/README.md` explaining credentials-on-Mac-only policy
- Root password from Secrets Manager `worxco/migrate-host/root-password`
- SSM agent snap + session-manager-plugin .deb
- RDS CA bundle in `/usr/local/share/ca-certificates/`
- `git config --global --add safe.directory` for root
- Endpoint helpers: `/usr/local/bin/{info-env,show-env,psql-env}`
  + `/usr/local/sbin/refresh-env-config` + sudoers file. Required
  because `run-pgloader.sh` sources `/etc/worxco/envs/sandbox` for
  `DRUPAL_DB_HOST` etc. **NOTE: dropping `use-env` and `valkey-env`
  from the helper set** — `use-env` manages FSx mounts (not needed),
  `valkey-env` manages Valkey connection (not needed for migration).
- Initial `refresh-env-config sandbox staging production`
- MOTD (updated to say "migrate-host")
- Admin SSH key sync from SSM registry

**ADD** (migrate-host-specific):
- `apt install mariadb-server mariadb-client pgloader postgresql-client gettext-base`
  (**gettext-base** is needed for envsubst in run-pgloader.sh; NO
  `nfs-common` because we don't mount FSx)
- `mkdir -p /var/tmp/migration` (dump staging dir on local disk)
- Write `/etc/mysql/mariadb.conf.d/99-migrate-host.cnf` (contents from §6.1)
- `systemctl enable --now mariadb` (**opposite** of deploy-host's
  `disable --now`)
- Write `/etc/worxco/migrate-host-marker`

**DO NOT include** (previously in the plan; removed after Kurt's review):
- `nfs-common` package
- Auto-`use-env sandbox` boot step (there's no FSx to mount)
- Anything that references `/var/www/mysql/` on FSx

---

## §9 — Backup/Restore Parity

Full parity with deploy-host per Kurt's explicit request. Files:

- `scripts/migrate-host/backup-state.sh` — near-verbatim clone of
  `scripts/deploy-host/backup-state.sh`. Swap `DEPLOY_HOST_BACKUPS_BUCKET`
  → `MIGRATE_HOST_BACKUPS_BUCKET`. Rename tarball keys.
  `BACKUP_PATHS[]` can be identical (same operator dotfiles, same intent).
- `scripts/migrate-host/restore-state.sh` — same treatment.

**For MVP, don't refactor into a shared library.** Copy is fine.
If a Phase-5+ refactor lands, a `scripts/common/backup-state-lib.sh`
sourced by both would reduce the duplication.

**Nightly EventBridge Scheduler**: cron `0 2 * * ? * America/Chicago`,
same as deploy-host. Fires SSM SendCommand → backup-state.sh fetched
from S3. If the instance is torn down at 02:00, SendCommand fails
silently (no target); harmless. If the instance is up (`keep` lifecycle
mode), backup captures state.

**Auto-restore on first boot**: UserData block, same shape as deploy-host.
Head-object on `config/migrate-host-latest.tar.gz`; if present, fetch
`restore-state.sh` from S3 and run with `CONFIRMED=yes`. First launch
after a destroy → deploy cycle brings back all operator state seamlessly.

---

## §10 — Makefile Targets

### 10.1 Top-level Makefile (infra lifecycle) — new targets

Mirror the deploy-host block (currently around Makefile:1820-2050):

- `deploy-migrate-host` — CFN deploy the stack
- `destroy-migrate-host` — CFN destroy (takes a final backup unless
  `SKIP_FINAL_BACKUP=yes`, matching `destroy-deploy-host` pattern)
- `ssm-migrate-host` — SSM Session Manager interactive shell
- `wait-migrate-host-ready` — block until cloud-init finishes + marker
  file exists (analog to `wait-deploy-host-ready`)
- `deploy-migrate-host-backups` — deploy the S3 backup bucket stack
- `destroy-migrate-host-backups`
- `backup-migrate-host` — dispatch backup-state.sh via SSM
- `restore-migrate-host` — dispatch restore-state.sh via SSM
- `list-migrate-host-backups` — S3 ls
- `refresh-migrate-host-scripts` — push updated /usr/local/sbin/
  helpers to the running instance after a git pull

**Naming parallels deploy-host exactly** — tab-completion muscle memory
translates directly.

### 10.2 Dispatch re-targeting (minimal-diff pattern)

Simplest change with smallest blast radius: add a `HOST_STACK` env-var
to `_ssm-run-deploy-host.sh` (line ~85), default `cf-deploy-host`,
override to `cf-migrate-host`. Two-line edit:

```bash
DEPLOY_HOST_STACK="${HOST_STACK:-cf-deploy-host}"
```

Then `dispatch-restore-mysql` and `dispatch-run-pgloader` accept
`HOST_STACK=cf-migrate-host` transparently — no new target names.
Backward compat: default behavior unchanged for anyone not passing
the env var.

### 10.3 `migrate-db-all` lifecycle wrapper

Add `MIGRATE_HOST_LIFECYCLE` env-var:

- `ephemeral` (default, recommended): deploy-migrate-host → run →
  destroy-migrate-host
- `keep`: deploy-migrate-host → run (leave up for the day)
- `none`: dispatch to deploy-host (legacy — for Phase 1-3 rollout only)

Phase sequence for `ephemeral` (**revised 2026-08-05 per Kurt's review**
— overlaps the CFN deploy with the preflight/backup work that
doesn't need the migrate-host):

1. `deploy-migrate-host &` — fire CFN deploy in **background** (~5-8 min)
2. Concurrently:
   - Phase -2: `refresh-env-config`
   - Phase -1: `verify-drupal-installed` preflight
   - Phase 0: `dispatch-db-backup` (safety-net backup of current sandbox DB)
3. `wait-migrate-host-ready` — join point, block until CFN + cloud-init done
4. Phase 1: `dispatch-restore-mysql HOST_STACK=cf-migrate-host`
5. Phase 2: `dispatch-run-pgloader HOST_STACK=cf-migrate-host`
6. `destroy-migrate-host CONFIRMED=yes`
7. Phase 3: `clear-drupal-cache` (unchanged — still hits deploy-host)

**Expected overlap savings**: 2-3 min. Preflights are fast (usually
under 2 min combined), so the CFN deploy is almost certainly still
running when they finish — the `wait-migrate-host-ready` at step 3
absorbs the remaining deploy time cleanly.

**Implementation note**: backgrounding `make` in a Makefile recipe
requires `&` + tracking the PID for `wait`. Cleaner: a small
`deploy-migrate-host-async` target that fires the deploy in the
background and returns immediately, plus `wait-migrate-host-ready`
blocking on the CFN stack reaching CREATE_COMPLETE + marker file
existing. Same pattern as any parallel-orchestration make target.

Once Phase 5 lands (deploy-host shrink), `ephemeral` becomes the
locked default and `none` is deprecated.

---

## §11 — Phased Rollout

Each phase is self-contained + verifiable before moving to the next.

### Phase 1 — Infra (bring the box up)

Write `cf-migrate-host.yaml` + `cf-migrate-host-backups.yaml` + params
+ `scripts/migrate-host/bootstrap.sh`. Add `deploy/destroy/ssm/wait-migrate-host`
Makefile targets.

**Verify** (all five must be green before proceeding):

- `make deploy-migrate-host` succeeds
- `make ssm-migrate-host` gives a shell
- `systemctl status mariadb` shows active
- `pgloader --version` prints (validates the SBCL binary is functional)
- `psql-env sandbox -c 'select 1'` reaches RDS (proves in-project-VPC
  network path + RDS SG ingress + endpoint-helper scripts all work)

### Phase 2 — Tuning (prove the speedup)

Land:
- `99-migrate-host.cnf` via bootstrap.sh (Phase 1's box gets replaced
  on next deploy; new one has tuned MariaDB from boot)
- `restore-mysql.sh` marker-guarded session-flag wrap
- `zinew.load.tmpl` WITH-block edits
- `PGLOADER_HEAP_MB` default 4096 → 10240 in run-pgloader.sh

**Verify**: manually run `sudo -E ./restore-mysql.sh` and `sudo -E
./run-pgloader.sh` on the migrate-host and time both. Targets:

- restore-mysql ≤ 5 min
- pgloader ≤ 12 min

If either misses, iterate on tuning BEFORE moving to Phase 3. Order:
drop concurrency first (`4 → 2`), then batch size (`100 MB → 50 MB`),
then workers (`4 → 2`).

### Phase 3 — Dispatch re-targeting

Add `HOST_STACK` env-var to `_ssm-run-deploy-host.sh`. Add all
backup/restore/list-migrate-host-backups Makefile targets.

**Verify**: `HOST_STACK=cf-migrate-host make dispatch-restore-mysql`
from Mac (or deploy-host) completes green — proves the SSM path
targets the right instance.

### Phase 4 — migrate-db-all integration

Add `MIGRATE_HOST_LIFECYCLE=ephemeral|keep|none` env-var wrapper
around `migrate-db-all`. Default `ephemeral`.

**Verify**: full unattended
`MIGRATE_HOST_LIFECYCLE=ephemeral make migrate-db-all AUTO=yes`
deploys the migrate-host, runs migration, destroys the migrate-host,
completes cleanly. Wall time compared to baseline.

### Phase 5 — Deploy-host shrink

In `scripts/deploy-host/bootstrap.sh`:

- Line 397-419: drop `mariadb-server mariadb-client pgloader
  postgresql-client` from the apt install list
- Line 428: drop the `systemctl disable --now mariadb` block
  (no longer relevant)

In `cloudformation/cf-deploy-host.yaml`:

- Line 183-189: delete the entire `fallocate -l 4G /swapfile` block
- Line 33: change `InstanceType` default `t4g.small` → `t4g.micro`
- Line 35-41: `AllowedValues` can drop `t4g.small` and above if
  desired (or leave; harmless)

Redeploy deploy-host (triggers instance replacement + auto-restore).

**Verify**: grep for `/usr/bin/pgloader` and `mariadb` in scripts/ —
any remaining references should be migrate-host-only or explicitly
noted as legacy paths.

---

## §12 — Non-Goals for MVP (explicit deferrals)

- **Pre-baked AMI** (Phase 6 candidate per Kurt's §2.1 comment).
  Baking a Packer/EC2-Image-Builder AMI with MariaDB + pgloader +
  tuning drop-in + bootstrap-installed tools pre-provisioned would
  drop first-boot time from ~3-4 min (bootstrap.sh) to ~90 sec
  (AMI resume). Real speed win, but not while we're iterating on
  tuning — every my.cnf tweak or WITH-block edit would require a
  new AMI bake. Right time to do this: after Phase 4 stabilizes
  and the tuning proves out across 3-5 successful ephemeral cycles.
- **pigz-parallel tar** for restore-files/codebase/private. Single-threaded
  `gzip` in `tar xzf` is a knob we could turn, but the underlying
  workload is FSx-I/O-bound — CPU parallelism from pigz doesn't
  meaningfully help. Add later only if profiling shows real time saved.
- **Separate EBS data volume for `/var/lib/mysql`**. Cleaner from a
  best-practice standpoint (dedicated IOPS pool for the DB) but adds
  complexity (mount point, permissions, my.cnf datadir override).
  For MVP the single-volume approach + provisioned IOPS is enough.
- **io2 storage tier**. gp3 maxes at 16000 IOPS / 1000 MB/s. Our tuned
  workload doesn't approach that ceiling. io2 costs ~4× per provisioned
  IOPS above 32000 — irrelevant unless MVP surprises us.
- **Multi-env parallel migrations**. Today one migrate-host services
  one env at a time. If we ever want to migrate sandbox + staging
  concurrently, we'd need per-env migrate-host stacks. Not needed for MVP.
- **Spot instance pricing**. Would cut ~$0.10/run off the $0.35 cost,
  but adds "spot got reclaimed mid-run" failure modes. Rounding error
  savings vs real complexity — skip.
- **Web UI / self-service provisioning**. This is operator infra;
  operators use `make`. Add later only if a non-operator persona
  needs to trigger migrations.
- **Sharing backup/restore code with deploy-host** via a common
  library. Copy is fine for MVP; refactor when maintenance cost
  starts to bite.

---

## §13 — Open Questions for Kurt to Consider (post-MVP)

None for MVP scope — all decisions locked in §4. These are
future-looking prompts to consider AFTER MVP proves out:

**Q1**: If a future client migration hits a 20+ GiB DB, does r7g.xlarge
(32 GiB) still fit? At what point should we upgrade to r7g.2xlarge
(64 GiB)? Suggest: any zinew-equivalent DB > 15 GiB triggers the
upgrade discussion.

**Q2**: Is the daily nightly-backup EventBridge Scheduler valuable
under `ephemeral` lifecycle (box is usually not up at 02:00)? Suggest
watching hit rate after MVP proves out. If it fires successfully <1×
per week, consider dropping the schedule or setting `State: DISABLED`.

**Q3**: Should the migrate-host's IAM role scope down from
`AdministratorAccess` (currently inherited from the deploy-host CFN
template)? Explicit scoping to just the migration-relevant services
(S3 migration bucket, Secrets Manager entries used by migration,
CloudFormation read for stack lookups, EC2 describe for peering
info) would be tighter. Not urgent — deploy-host has been running with
`AdministratorAccess` for months without incident — but for a future
security review pass, worth revisiting.

**Q4**: Is the deploy-host t4g.micro downgrade (Phase 5) too tight
after we drop pgloader/MariaDB? Verify that composer + drush + node
still have breathing room on 1 GiB RAM. If not, hold at t4g.small.

---

## Appendix A — Deploy-host architecture map (from Explore agent 1, 2026-08-05)

### A.1 CFN Template
- Primary: `cloudformation/cf-deploy-host.yaml`
- Params: `cloudformation/parameters/deploy-host.json` (overrides `InstanceType`)
- `InstanceType` default `t4g.small`, AllowedValues `[t4g.nano,micro,small,medium]` — Graviton only
- `UbuntuAMI` SSM public parameter `/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id` (:45)
- EC2: default VPC, single SG, no KeyName (SSM only), single EBS `/dev/sda1` gp3 20 GiB encrypted (:142-148)

### A.2 IAM
- Role assumed by `ec2.amazonaws.com` (:78-105)
- Managed policies: `AmazonSSMManagedInstanceCore` + `AdministratorAccess` (broad, no inline policies)
- Instance profile `${AWS::StackName}-profile`

### A.3 SSM Session Manager
- Account-wide `SSM-SessionManagerRunShell` document forcing
  `runAsDefaultUser: ubuntu` + `cd ~ && exec bash -l` (:114-128)
- **THIS DOCUMENT MUST NOT BE DUPLICATED** by cf-migrate-host

### A.4 Security Group
- No ingress rules at all (:62-72)
- Default egress open
- Exported as `${StackName}-sg-id`

### A.5 EventBridge Backup Scheduler
- `DeployHostSchedulerRole` with inline `SendCommandToDeployHost`
  policy scoped to ssm:SendCommand against this instance ARN +
  `AWS-RunShellScript` document (:358-369)
- Cron `0 2 * * ? *` in `America/Chicago` (:383-384)
- Payload fetches `_common.sh` + `backup-state.sh` from S3 then executes

### A.6 Peering (`cf-deploy-peering.yaml`)
- Params: EnvironmentName, DeployHostStackName, DefaultVpcId,
  DefaultVpcCidr (default `172.31.0.0/16`), DefaultVpcRouteTableId,
  AZCount (:37-68)
- Creates peering (:81-91), route default→project (:97-103), routes
  project public + private-1/2/3 back (:110-142)
- Cross-VPC SG ingress on project SGs sourced from deploy-host SG:
  FSx 2049 (:152-162), FSx portmapper 111 (:165-175),
  RDS 5432 (:178-188), Valkey 6379 (:191-201)
- `DefaultVpcId`/`DefaultVpcRouteTableId` resolved at deploy time
  by Makefile:2138-2170

### A.7 Bootstrap (692 lines)
Path: `scripts/deploy-host/bootstrap.sh`. See §3.1 for install list.

### A.8 Backup/restore
- Backup: `scripts/deploy-host/backup-state.sh` (400 lines) —
  `BACKUP_PATHS[]` at :148-196
- Restore: `scripts/deploy-host/restore-state.sh` (430 lines) —
  seven-phase flow (:30-40)

---

## Appendix B — MariaDB + pgloader current-state deep-dive (from Explore agent 2, 2026-08-05)

### B.1 MariaDB installation
- `bootstrap.sh:397-418` — `apt-get install mariadb-server
  mariadb-client` (Ubuntu 24.04 arm64)
- `bootstrap.sh:421-429` — `systemctl disable --now mariadb`
  immediately after install (comment: "scratch DB for test
  migrations only … costs ~100 MB RAM idling")
- **No custom my.cnf anywhere in the repo** (greppd bootstrap.sh,
  all of image-builder/, all of cloudformation/, all of scripts/)
- Data dir `/var/lib/mysql` on 20 GiB root gp3 (baseline 3000 IOPS)
- Dump staged at `/var/www/mysql/zinew.sql` (FSx NFS mount)

### B.2 restore-mysql.sh
- 6 phases (header :14-22): preconditions → confirm → S3 fetch →
  sed sanitize → drop+recreate → `mysql < dump.sql`
- Line 283: `mysql -h 127.0.0.1 -u "$LOCAL_DB_USER"
  -p"$LOCAL_DB_PASS" "$LOCAL_DB_NAME" < "$DUMP_LOCAL_PATH"` — no flags
- Pre-restore prep (:243-256): DROP DATABASE / CREATE DATABASE
  utf8mb4_unicode_ci / CREATE USER worxco@127.0.0.1 / GRANT ALL / FLUSH
- Sanitize (:205-219): `sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'`
- Env vars honored (:60-65): MIGRATION_BUCKET, DUMP_S3_KEY,
  DUMP_LOCAL_PATH, LOCAL_DB_NAME, LOCAL_DB_USER, LOCAL_DB_PASS,
  FORCE_DOWNLOAD, CONFIRMED, DRY_RUN

### B.3 run-pgloader.sh
- Line 296-298: `pgloader --dynamic-space-size "$PGLOADER_HEAP_MB"
  --no-ssl-cert-verification "$RENDERED_PATH"`
- `PGLOADER_HEAP_MB` default 4096 at :98
- HOME=/root forced at :82 (SBCL debugger hang guard)
- Template: `migration/pgloader/zinew.load.tmpl` envsubst-rendered
  to `/tmp/zinew.load` (:276-278), chmod 600, shredded on exit

### B.4 pgloader template (`migration/pgloader/zinew.load.tmpl:56-65`)
```
WITH include drop, create tables, create indexes,
     reset sequences, foreign keys, downcase identifiers,
     batch rows = 500,        -- :62
     prefetch rows = 500,     -- :63
     workers = 2,             -- :64
     concurrency = 1          -- :65
```

### B.5 Historical context
- Template comments (:30-37) + commit a3d10e4 document progression:
  defaults (~25000/1000) → OOM on 2 GB swap → 250 (safe) → 500 (current)
- All four tunables hardcoded in template (not envsubst)
- SBCL heap only env-tunable via `PGLOADER_HEAP_MB`

### B.6 Makefile orchestration
- `restore-mysql` target: `migration/Makefile:688-719`
- `run-pgloader` target: `migration/Makefile:721-749`
- `dispatch-restore-mysql` / `dispatch-run-pgloader`: `:812-822`
  → both call `./scripts/_ssm-run-deploy-host.sh <script>`
- `_ssm-run-deploy-host.sh` uploads `_common.sh` + target script +
  zinew.load.tmpl to S3, then `aws ssm send-command AWS-RunShellScript`
  with `POLL_TIMEOUT=7200` (2h default)
- `migrate-db-all` phases (:844-1001): -2 refresh-env, -1 preflight,
  0 db-backup, **1 dispatch-restore-mysql (:975-978)**,
  **2 dispatch-run-pgloader (:981-985)**, 3 clear-drupal-cache
- Timing notes: Makefile:983 "up to 2 hours for full 12M-row load";
  Makefile:529-532 dumps ~10-15 min

---

## Appendix C — Design Rationale Deep-Dives

### C.1 Why r7g.xlarge, not m7g.xlarge

Both are Graviton 3, both meet Kurt's floor (4 vCPU / 16 GiB). The
difference is 32 GiB vs 16 GiB RAM at a $0.05/hr delta.

**On 16 GiB (m7g.xlarge)** we'd have to allocate:
- MariaDB buffer pool: ~6 GiB (down from ideal 8)
- SBCL pgloader heap: ~6 GiB (down from ideal 10)
- OS + tools + slack: ~4 GiB
- Total: 16 GiB — zero headroom

Any unexpected memory spike (a wide-row table, larger dump than
expected, pgloader working-set overflow) → OOM. And the whole
POINT of moving to a bigger box was to STOP tuning down.

**On 32 GiB (r7g.xlarge)**:
- MariaDB buffer pool: 8 GiB
- SBCL pgloader heap: 10 GiB
- OS + tools: ~4 GiB
- Slack: 10 GiB — comfortable

Extra cost: $0.05/hr × 1 hr = ~$0.05/run. For ~30 runs/month = $1.50.
Rounding error vs the operator's time cost of iterating on tuning
because the box was undersized.

### C.2 Why concurrency=4 is the biggest wall-time win

pgloader today runs `concurrency=1` — that means ONE table is loaded
at a time. If the DB has N tables and each takes T_i seconds, wall
time is `Σ T_i` (sum). With `concurrency=4`, up to 4 tables load
in parallel, and wall time approaches `max(T_i)` (the largest table)
plus queue delays for smaller tables.

For zinew's shape (2.4 GB, mix of small reference tables + a few big
node tables), the wall-time reduction is roughly a factor of ~3-4×
just from parallelism — before ANY other tuning takes effect.

`workers=4` (up from 2) also helps but is subordinate — workers are
per-table threads within a single-table load. `workers=4` is pgloader's
own default and matches the 4-vCPU box.

`batch rows=5000` (up from 500) is a linear speedup on top — 10× fewer
INSERT round-trips to RDS. Meaningful but not game-changing.

Combined effect: `concurrency=4` gets ~3-4× wins wall-time; other
knobs each add ~10-30%.

### C.3 Why migrate-host lives in project VPC (not default VPC)

Deploy-host lives in the default VPC specifically so it can survive
`destroy-all` — it's a control-plane host that outlives any given
environment's project VPC. That was the right call for deploy-host.

Migrate-host has a completely different lifecycle: **it only exists
during a migration run**. It doesn't need to survive `destroy-all`
because a `destroy-all` implies you're rebuilding, which implies
you'd need to `migrate-full-all` again after, which implies a new
migrate-host anyway.

Given migrate-host is scoped to a single environment's migration
window, placing it INSIDE that environment's project VPC removes
an entire class of complexity:

- No peering resources
- No routes on either side
- No cross-VPC SG references
- No `cf-migrate-peering.yaml`
- No dependency on `cf-deploy-peering.yaml` for network access
- Direct SG-to-SG ingress on RDS (one 5-line YAML block, inline)

SSM SendCommand (the ONLY way anything talks to migrate-host from
outside — deploy-host or Mac) uses AWS APIs, not the VPC network
path. So no peering is needed for control-plane traffic either.

This was a design bug I made in the original draft — Kurt caught it
in his 2026-08-05 review. Documenting the corrected reasoning here
so future-me doesn't reintroduce the mistake.

### C.4 Why bulk-load MariaDB tuning is safe for a throwaway box

The tuning in §6.1 turns off durability features:
`flush_log_at_trx_commit=0`, `doublewrite=0`, `sync_binlog=0`,
`skip_log_bin`. In a production MariaDB these would be dangerous
— a crash could lose the last second of transactions, corrupt
tablespace on unclean shutdown, etc.

For the migrate-host:
- No production traffic hits this MariaDB. It's a staging DB.
- If it crashes mid-restore, we simply destroy the instance and rerun.
- The DB is discarded at the end of the migration anyway (pgloader
  read from it → we don't need it after).
- Any corruption is caught by pgloader's post-load validation
  (`create indexes, reset sequences, foreign keys`).

The tuning is a textbook example of "durability tunables you turn
OFF for one-time bulk imports and turn back ON for steady-state
production."

---

## Cross-references

- `docs/plans/multi-tenant-refactor-review-2026-07-31.md` — same
  doc-shape + reviewer convention. Read that if you liked this
  format and want to compare styles.
- `docs/plans/multi-tenancy.md` — long-form multi-tenancy planning
  (unrelated to migrate-host but useful context on Phase-C→H roadmap).
- `docs/FSX-LAYOUT.md` — authoritative FSx directory structure,
  ownership, mount model. Read if you want to understand why
  `/var/www/mysql/` dump staging works on the migrate-host too.
- `docs/DEPLOY-HOST.md` (if it exists) — deploy-host role documentation.
  If not written yet, this doc's §3.1 covers the deploy-host essentials.
- `docs/memory/drupal-update-management.md` (per bootstrap.sh comment) —
  the "why we uninstall the Update Manager module" doc; unrelated to
  migration but referenced by install-drupal.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
