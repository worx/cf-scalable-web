---
name: Migration runbook (prod → sandbox)
description: Step-by-step operator runbook for migrating Drupal data + codebase from the prod account (978068244875) into sandbox. Cross-account ferry via a small SSM-only jumpbox.
audience: operator
created: 2026-06-12
---

# Prod → Sandbox Drupal Migration Runbook

One-time procedure to copy a Drupal site from the legacy prod account
(`978068244875`, MySQL on Aurora) into the sandbox account (PostgreSQL
on RDS, FSx-backed Drupal). Used to rehearse the eventual production
migration before committing.

## Source details (from operator 2026-06-12)

| What | Value |
|------|-------|
| Source EC2 (Drupal codebase) | `React2` (`i-044329095f5c3a821`) |
| Source RDS endpoint | `d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com` |
| Source DB engine | Aurora MySQL 8.0 |
| Source database name | `zinew` |
| Source DB user | `worxco` |
| Source DB password | (operator-supplied at runtime — NOT committed) |
| Sandbox PostgreSQL target | (read from SSM `/sandbox/rds/endpoint` at run time) |
| AWS profiles required locally | `ZI-Sandbox` (sandbox account), `ZoningInfoAdmin` (prod account) |

## Architecture: two-stack ferry

```
   PROD ACCOUNT 978068244875            SANDBOX ACCOUNT (ZI-Sandbox)
   ┌───────────────────────┐            ┌────────────────────────┐
   │ React2 (Drupal code)  │            │ deploy-host            │
   │ d8demo-cluster (MySQL)│            │   pgloader, mysql-cli  │
   │                       │            │                        │
   │      ┌────────────┐   │            │      ┌──────────────┐  │
   │      │ jumpbox    │───┼────────────┼─────▶│ migration    │  │
   │      │ (t4g.micro)│   │  S3 write  │      │ S3 bucket    │  │
   │      └────────────┘   │ (x-account)│      └──────────────┘  │
   └───────────────────────┘            │              │         │
              ▲                         │              ▼         │
              │ SSM Session             │       sandbox RDS PG   │
              │ (from operator Mac)     │       FSx /var/www     │
              │                         └────────────────────────┘
```

Two CloudFormation stacks:

- **`cf-scalable-web-sandbox-migration-bucket`** (SANDBOX) — an S3 bucket
  with a cross-account bucket policy that allows ONLY the prod jumpbox
  role to write. Lifecycle rule expires migration artifacts after 30 days.
- **`cf-migration-jumpbox`** (PROD) — t4g.micro Ubuntu in
  `subnet-85e938dc` (same subnet as React2). No inbound SG rules.
  IAM role has SSM access + scoped `s3:PutObject` to the sandbox bucket.

Both are explicitly addressed via `--profile` flags in the Makefile,
so the wrong account can't be hit by accident.

## Step-by-step

### 1. One-time setup (~5 min)

Deploy the bucket first (it needs to exist before the jumpbox role
can write to it):

```bash
make deploy-migration-bucket
# Verify output: stack creates, prints MigrationBucketName + MigrationBucketArn
```

Then the jumpbox:

```bash
make deploy-migration-jumpbox
# Verify output: prints JumpboxInstanceId, JumpboxPrivateIp, JumpboxRoleArn
```

The jumpbox's UserData takes ~2 minutes to install `mysql-client-core`,
`pigz`, `rsync`, and the AWS CLI v2. SSM is available immediately though.

### 2. Authorize the jumpbox to SSH into React2 (~2 min)

The jumpbox needs an SSH key authorized on React2 for `rsync`. There's
no automated way to do this without giving React2 itself an SSM-eligible
IAM role (a bigger change to prod than we want).

**Generate + retrieve the jumpbox pubkey:**

```bash
make migration-jumpbox-pubkey
# Output: ssh-ed25519 AAAA...== root@cf-migration-jumpbox
```

Copy that pubkey line.

**Add it to React2's `authorized_keys`** using your existing SSH access
to React2 (your IP is in the `WebSSH` SG ingress list, or use the
Worxco prefix list):

```bash
# from your Mac
ssh ubuntu@<React2-public-IP>
sudo -i
echo 'ssh-ed25519 AAAA...== root@cf-migration-jumpbox' \
  >> /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
exit; exit
```

(Adjust the user — `ubuntu` is the standard Ubuntu AMI default but
React2 may use something else.)

### 3. Verify jumpbox connectivity (~1 min)

Get an interactive shell on the jumpbox:

```bash
make ssm-migration-jumpbox
```

Inside that shell:

```bash
# Confirm MySQL access to prod RDS:
mysql -h d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com \
      -u worxco -p -e "SELECT VERSION();" zinew

# Confirm SSH to React2 (replace IP):
ssh -o StrictHostKeyChecking=accept-new ubuntu@172.31.23.46 hostname

# Confirm S3 write to sandbox migration bucket:
echo "test from jumpbox $(date -u)" | \
  sudo aws s3 cp - s3://sandbox-migration-kv-worxco/health-check.txt
```

If all three succeed, you're ready to migrate.

### 4. Database dump → S3 (~few min, depends on DB size)

On the jumpbox:

```bash
# Stream mysqldump → gzip → S3, no intermediate file on disk.
# --single-transaction for InnoDB consistency without locking writes.
# --quick for memory efficiency on large tables.
# --routines + --triggers to capture stored procs / triggers Drupal modules use.
sudo mysqldump \
    -h d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com \
    -u worxco -p \
    --single-transaction --quick \
    --routines --triggers \
    --set-gtid-purged=OFF \
    zinew \
  | pigz \
  | sudo aws s3 cp - s3://sandbox-migration-kv-worxco/zinew-$(date -u +%Y%m%d-%H%M%S).sql.gz
```

You'll be prompted for the prod DB password. Output object key includes
a timestamp so re-runs don't overwrite earlier dumps.

### 5. Codebase tarball → S3 (~few min, depends on codebase size)

Still on the jumpbox:

```bash
# rsync from React2 to local /tmp first (lets rsync resume on connection
# blips); then tar+pigz+S3 in a separate step.
# Adjust the source path to wherever Drupal lives on React2.
sudo rsync -av --delete \
  ubuntu@172.31.23.46:/var/www/zinew/ \
  /tmp/zinew-codebase/

sudo tar -C /tmp -cf - zinew-codebase \
  | pigz \
  | sudo aws s3 cp - s3://sandbox-migration-kv-worxco/zinew-codebase-$(date -u +%Y%m%d-%H%M%S).tar.gz

# Optional: clean up local copy
sudo rm -rf /tmp/zinew-codebase
```

### 6. Pull artifacts to the sandbox deploy-host (~few min)

SSM into the sandbox deploy-host (a separate session — NOT the jumpbox):

```bash
# From your Mac
DEPLOY_ID=$(aws --profile ZI-Sandbox ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws --profile ZI-Sandbox ssm start-session --target $DEPLOY_ID
```

On the deploy-host:

```bash
# List what's in the migration bucket
aws s3 ls s3://sandbox-migration-kv-worxco/

# Pull the database dump (replace timestamp with what you saw earlier)
aws s3 cp s3://sandbox-migration-kv-worxco/zinew-YYYYMMDD-HHMMSS.sql.gz /tmp/

# Pull the codebase
aws s3 cp s3://sandbox-migration-kv-worxco/zinew-codebase-YYYYMMDD-HHMMSS.tar.gz /tmp/
```

### 7. MySQL → PostgreSQL conversion via pgloader

Still on the deploy-host:

```bash
# Decompress dump (or pipe pgloader's mysql-style command at it directly —
# but file-based load is more robust for first runs)
sudo zcat /tmp/zinew-YYYYMMDD-HHMMSS.sql.gz > /tmp/zinew.sql

# Read the sandbox RDS PostgreSQL connection details
source /etc/worxco/envs/sandbox  # populates DRUPAL_DB_HOST, DRUPAL_DB_PORT, etc.

# Convert (see docs/memory/test-environment-design.md for the strategy.
# This is the file-based path; live-MySQL-to-live-PG via pgloader is
# also viable if we ever want to skip the dump-to-S3 step).
#
# pgloader has a Drupal preset that handles common type translations
# (LONGTEXT → TEXT, TINYINT(1) → BOOLEAN, AUTO_INCREMENT → SEQUENCE).
# Document the migration command we used here once tested.
pgloader \
  --type mysql-file \
  /tmp/zinew.sql \
  postgresql://${DRUPAL_DB_USER}:${DRUPAL_DB_PASS}@${DRUPAL_DB_HOST}:${DRUPAL_DB_PORT}/${DRUPAL_DB_NAME}
```

(The exact pgloader invocation will need iteration on the first run —
expect to refine the command based on what the source schema actually
looks like.)

### 8. Codebase deploy onto FSx

On the deploy-host:

```bash
# Make sure FSx is mounted (use-env handles this)
sudo use-env sandbox

# Extract codebase into Drupal's location on FSx
sudo tar -xzf /tmp/zinew-codebase-YYYYMMDD-HHMMSS.tar.gz -C /tmp/
sudo rsync -av --delete /tmp/zinew-codebase/ /var/www/drupal/

# Re-run permissions step (PHP-FPM writes — see install-drupal.sh)
# … or invoke a smaller permissions-only script if we extract one
```

### 9. Verify the migrated site

```bash
# Drush status against the migrated DB
cd /var/www/drupal
sudo -E HOME=/root vendor/bin/drush status

# Then the standard smoke tests
make smoke-test-drupal ENV=sandbox     # from your Mac, in the cf-scalable-drupal repo
make smoke-test-public ENV=sandbox
```

### 10. Cleanup when migration testing is done

```bash
# Order matters: destroy the prod jumpbox FIRST (so the bucket-policy
# Principal is no longer referenced), THEN the bucket.
make destroy-migration-jumpbox CONFIRMED=yes
make destroy-migration-bucket CONFIRMED=yes
```

You may also want to remove the jumpbox's ED25519 pubkey from React2's
`authorized_keys` when you're done — the jumpbox is gone, but the key
sitting in `authorized_keys` is operational debt.

## Things to watch for

- **mysqldump password** — supplied interactively via `-p` (no echo).
  Avoid `-pPASSWORD` (visible in `ps`) and avoid `MYSQL_PWD` in the env
  (visible in `/proc`). Operator types it; not committed anywhere.
- **Drupal version drift** — if `React2`'s Drupal core differs from
  what we install in sandbox (we install Drupal 11), the schema won't
  match. The very first run should confirm core version via
  `drush status` on React2 before mass-loading data.
- **Charset / collation** — Aurora MySQL 8.0 default charset may differ
  from what pgloader expects. If pgloader complains about charset, add
  `--from-encoding utf8` (or specific collation) options.
- **S3 lifecycle** — the migration bucket expires objects after 30 days.
  If you need them longer, edit `cf-migration-bucket.yaml`'s
  `ExpirationInDays` or pull artifacts out before then.

## Why this design

- **Cross-account via SSM, not VPC peering.** Peering would require
  routing-table changes in prod that persist beyond the migration.
  SSM tunnel is established and torn down per session.
- **Jumpbox in same subnet as React2 (subnet-85e938dc).** Free SSH and
  RDS access via existing SG rules; zero modifications to prod SGs.
- **Bucket policy restricts to a role-name PATTERN.** Even though the
  policy's Principal is the prod account, the `aws:PrincipalArn`
  condition means only the jumpbox role can actually write. If the
  jumpbox is destroyed and someone tries to write from a different
  prod role, the bucket rejects it.
- **No public IP, no inbound rules.** SSM Agent's outbound TLS does
  all the work. Attack surface is effectively zero.

## Open questions to resolve on first run

- [ ] Drupal core version on React2 → drives whether we land in sandbox
      as the same version, then upgrade, or run on the source version.
- [ ] PHP version on React2 → drives which sandbox PHP pipeline we
      target (php74 ASG for D7/D9, php83 for D10/D11).
- [ ] DB size + table count → sets expectations for dump/transfer/load
      timing.
- [ ] Whether site-specific config files reference absolute paths that
      need translation when moving from React2's filesystem to FSx.

These are captured here rather than in the script because they need
human judgment after first inspection.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
