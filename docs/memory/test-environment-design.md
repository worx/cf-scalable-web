---
name: Test environment design
description: Design discussion for a `test` env as a prod-migration rehearsal — dual-AZ, MySQL→Postgres via pgloader, stop/start automation
type: project
created: 2026-05-21
---

# Test Environment Design Discussion (2026-05-21)

Captures the design discussion for standing up a `test` environment alongside
`sandbox`. The intent of `test` is to be a **prod-migration rehearsal env** —
not just "a second sandbox". Decisions here are biased toward "test should
teach us how prod will behave," even when that costs slightly more.

This is a design memo, not yet implemented. Sequencing at the bottom.

---

## Goal

Stand up a `test` env that mirrors prod topology, then practice copying the
current production Drupal site into it — including the MySQL → PostgreSQL
migration. Once the rehearsal works, the same procedure cuts prod over.

## Single-zone vs dual-zone — decision: **dual-zone**

The instinct to go single-AZ for test (cost savings) was the first item under
discussion. The math:

| Resource | Multi-AZ | Single-AZ | Delta |
|----------|----------|-----------|-------|
| FSx OpenZFS (100GB) | ~$36/mo | ~$18/mo | $18/mo |
| RDS db.t4g.micro    | ~$26/mo | ~$13/mo | $13/mo |
| **Total persistence-tier savings** | | | **~$31/mo** |

That ~$31/mo is small compared to the rehearsal value you give up:
- Multi-AZ RDS failover behavior (connection-string handling, replica lag)
- FSx OpenZFS Multi-AZ failover semantics — worth seeing in test BEFORE prod
- ALB cross-AZ routing
- ASG distribution math at scaling events

The compute cost dominates the bill anyway, and that's where ASG sizing +
`pause-compute` does the real work. **Recommendation:** dual-AZ everywhere
(matching prod), but daytime ASG `desired=1` (one nginx + one php74 + one
php83) instead of 2-of-each. ~50% compute savings during business hours, full
shutdown overnight, topology still matches prod.

## What can be stopped vs not

| Component | Stoppable? | Notes |
|-----------|-----------|-------|
| ASGs (NGINX/PHP)    | ✅ | `pause-compute` exists (commit 1e48a92); sets desired=0 |
| RDS                 | ✅ | `aws rds stop-db-instance`. **7-day max** — AWS auto-starts after. Multi-AZ DB *instances* can stop; Multi-AZ DB *clusters* cannot. |
| ElastiCache Valkey  | ❌ | No stop API. Only destroy/recreate. |
| FSx OpenZFS         | ❌ | No stop API. Pay 24/7. Data persists indefinitely — no loss risk. |
| ALB                 | ✅ (sort of) | Can delete; pay ~$16/mo otherwise. Recreating changes DNS. |

**Stop-test sequence:**
1. `pause-compute` → ASGs to 0
2. `aws rds stop-db-instance` (re-poke every 6 days if stopped >7 days)
3. Optionally `destroy-cache` (Valkey recreates in ~3 min; cold cache is fine for test)
4. Leave FSx + ALB running

Overnight cost drops to roughly FSx + ALB + (cache if not destroyed) =
~$50/mo baseline vs ~$200+/mo full-running.

## FSx and Valkey persistence questions

**Q: Does FSx survive stop/restart without losing data?**
A: FSx OpenZFS data is durable. There's no stop, but there's also no risk.
Snapshots are separate and can be scheduled.

**Q: Can Valkey offload its cache before stopping so it restarts warm?**
A: Yes, with effort: `aws elasticache create-snapshot` → S3, then on recreate
use `--snapshot-name` to restore. For test, skip the snapshot choreography —
Drupal handles cold caches fine (first few page loads slower, then rebuilt).
For prod, that pattern is the right one.

## MySQL → PostgreSQL migration — decision: **do it now**

Punting to MySQL "until we figure out the migration" defeats the rehearsal
purpose of test. The whole point is to learn the migration on test before
running it against prod.

**Toolchain choice: pgloader from the deploy-host.**

- Open-source, fast (1–2 min for typical Drupal DBs)
- Drupal-aware presets handle the schema gotchas:
  - `LONGTEXT` / `MEDIUMTEXT` → `TEXT`
  - `TINYINT(1)` → `BOOLEAN`
  - AUTO_INCREMENT → SEQUENCE
  - Index translation
- Single command:
  ```
  pgloader mysql://user:pass@prod-mysql/drupal \
           postgres://drupal_user:pass@test-rds/drupal
  ```

After load, one `drush cache:rebuild` and the site is live.

**Alternative considered: AWS DMS.** More infrastructure for a one-shot job
(replication instance, endpoints, migration task definitions). pgloader is
simpler for this use case. DMS would be the right call if we wanted
continuous replication during a long cutover; for a point-in-time copy,
pgloader wins.

## Drupal + PHP version compatibility — gating question

| Drupal | Officially supported PHP |
|--------|--------------------------|
| 7 (EOL Jan 2025)     | 7.4 (or 8.1/8.2 with php-next patches) |
| 9.x (EOL Nov 2023)   | 7.4 / 8.0 / 8.1 |
| 10.x                 | 8.1+ |
| 11.x                 | 8.3+ |

If prod is Drupal 7 or 9.x, we need the **php74** pipeline (already pre-baked
— exactly why we built it). If prod is Drupal 10, php83 works. Multiple PHP
versions can run side-by-side in the same env via the port-routing design
(9074, 9083) — no architectural problem.

**Action item:** get prod's `drush status --field=drupal-version --field=php-version`
output before any of the above can move.

## Sequencing

1. **Get prod's drush status output.** Decides which PHP pipeline test needs.
2. **Verify `make deploy-allX ENV=test` works.** Sandbox is already parameterized;
   may just work, or may surface env-name assumptions that need lifting.
3. **Add `make stop-test` / `make start-test`** wrapping pause-compute +
   stop-rds + (optionally) destroy-cache. Consider EventBridge schedule for
   weekday-business-hours auto on/off.
4. **Write `make migrate-from-prod ENV=test`** that wraps pgloader +
   `drush cache:rebuild`.
5. **Decide which prod files come over** (drupal-private/, sites/default/files/,
   salt.txt). That's an rsync from prod-FSx to test-FSx — doable via deploy-host
   if VPC peering exists, or via S3 staging.

## Why dual-AZ over single-AZ — restated

Test exists to teach us how prod will behave. Single-AZ test diverges from
prod in exactly the dimensions (failover, AZ routing, ASG math) that bite
during real prod incidents. The ~$31/mo persistence-tier saving from going
single-AZ isn't worth losing that rehearsal fidelity. Spend the money on the
match-prod topology; save real money by aggressive stop/start automation on
the parts that CAN be stopped (compute, RDS).
