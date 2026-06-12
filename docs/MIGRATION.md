---
name: Migration runbook (prod → sandbox)
description: Step-by-step operator runbook for migrating Drupal data + codebase from the prod account (978068244875) into sandbox. Cross-account via a small SSM-only jumpbox; pgloader does live MySQL→PostgreSQL conversion.
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
| Sandbox PostgreSQL target | (read from `/etc/worxco/envs/sandbox` at run time) |
| AWS profiles required locally | `ZI-Sandbox` (sandbox account), `ZoningInfoAdmin` (prod account) |

## Architecture

```
   PROD ACCOUNT 978068244875            SANDBOX ACCOUNT (ZI-Sandbox)
   ┌───────────────────────┐            ┌──────────────────────────┐
   │ React2 (Drupal code)  │            │ deploy-host              │
   │ d8demo-cluster (MySQL)│            │  ├ pgloader              │
   │                       │            │  ├ session-manager-plugin│
   │      ┌────────────┐   │  SSM port  │  └ ~/.aws/credentials    │
   │      │ jumpbox    │◀──┼─ forward ──┤      (ZoningInfoAdmin)   │
   │      │ (t4g.micro)│   │   prod RDS │             ▲            │
   │      └─────┬──────┘   │  to local  │             │            │
   │            │ S3 write │   :3306    │  pgloader uses:           │
   │            ▼          │            │   - localhost:3306        │
   │     S3 codebase ──────┼───────────▶│     (prod MySQL via SSM)  │
   │     ferry             │            │   - sandbox RDS:5432      │
   └───────────────────────┘            │     (native VPC access)   │
                                        └──────────────────────────┘
```

Two transports across the account boundary:

- **DB**: live MySQL exposed at `localhost:3306` on the deploy-host via
  an SSM port-forwarding session through the jumpbox. **pgloader needs
  a live MySQL connection — it has no "load from mysqldump file" mode**,
  so this is the correct shape. Live conversion also lets you re-run
  with tweaked casts without re-fetching from prod.
- **Codebase**: rsync from React2 → jumpbox's local disk → tar+gzip+S3
  (sandbox migration bucket) → deploy-host pulls and extracts onto FSx.

The migration bucket is still used **for codebase only**. No mysqldump
intermediate file.

## Step-by-step

### 1. One-time stack setup (~5 min)

Deploy the sandbox-side bucket first (it needs to exist before the
jumpbox can write to it):

```bash
make deploy-migration-bucket           # SANDBOX, profile ZI-Sandbox
make deploy-migration-jumpbox          # PROD, profile ZoningInfoAdmin
```

The jumpbox's UserData takes ~2 min to install `mysql-client-core`,
`pigz`, `rsync`, and AWS CLI v2. SSM Session Manager is available
immediately though.

### 2. Authorize the jumpbox to SSH into React2 (~2 min)

The jumpbox needs an SSH key authorized on React2 for `rsync`. There's
no automated way to do this without giving React2 itself an SSM-eligible
IAM role (a bigger change to prod than warranted for this work).

Generate the jumpbox pubkey:

```bash
make migration-jumpbox-pubkey
# Output: ssh-ed25519 AAAA...== root@cf-migration-jumpbox
```

Copy that line, then SSH into React2 (using your existing access — the
`WebSSH` SG ingress covers your IP or your Worxco prefix list) and add
the pubkey to React2's `authorized_keys`:

```bash
# from your Mac
ssh ubuntu@<React2-public-IP>
sudo -i
echo 'ssh-ed25519 AAAA...== root@cf-migration-jumpbox' \
  >> /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
exit; exit
```

### 3. Verify jumpbox connectivity (~1 min)

```bash
make ssm-migration-jumpbox
```

Inside the jumpbox shell:

```bash
# Confirm MySQL access to prod RDS
mysql -h d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com \
      -u worxco -p -e "SELECT VERSION();" zinew

# Confirm SSH to React2 (private IP; React2's WebSSH SG allows
# everything from 172.31.16.0/20, the subnet you're sharing)
ssh -o StrictHostKeyChecking=accept-new ubuntu@172.31.23.46 hostname

# Confirm S3 write to sandbox migration bucket
echo "test from jumpbox $(date -u)" | \
  sudo aws s3 cp - s3://sandbox-migration-kv-worxco/health-check.txt
```

If all three succeed, the jumpbox infrastructure is good to go.

### 4. Set up `ZoningInfoAdmin` credentials on the sandbox deploy-host (~2 min)

The deploy-host needs to start an SSM port-forwarding session against
the prod jumpbox — which means it needs prod credentials. We're going
with **temporary credential ferry to the deploy-host** (Option A): the
deploy-host is itself ephemeral (won't survive a `destroy-all` cycle),
SSM is the only access path, and the operator is the only user. Risk
is low.

From your Mac, SSM into the sandbox deploy-host:

```bash
DEPLOY_ID=$(aws --profile ZI-Sandbox ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws --profile ZI-Sandbox ssm start-session --target $DEPLOY_ID
```

Inside the deploy-host:

```bash
# Install the SSM Session Manager plugin (needed to ORIGINATE SSM
# sessions, not just to receive them — Ubuntu ARM64 build):
sudo curl -sSL \
  "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" \
  -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
rm /tmp/session-manager-plugin.deb

# Verify
session-manager-plugin --version

# Create the .aws config (as the ubuntu user, not root)
mkdir -p ~/.aws
chmod 700 ~/.aws

# Add the ZoningInfoAdmin profile config + credentials
# (paste the exact lines from your local ~/.aws/config and
#  ~/.aws/credentials for the [ZoningInfoAdmin] profile)
nano ~/.aws/config
nano ~/.aws/credentials
chmod 600 ~/.aws/config ~/.aws/credentials

# Sanity check that the credentials work cross-account:
aws --profile ZoningInfoAdmin sts get-caller-identity
# Should show account 978068244875
```

**Cleanup at end of migration:** `rm ~/.aws/credentials` (or remove just
the `[ZoningInfoAdmin]` block). Also note in the followups list to
restore from the latest known-good state if a `destroy-all` /
`deploy-allXX` cycle happens before cleanup — the deploy-host gets
rebuilt and the credentials disappear naturally.

### 5. Open the SSM port-forwarding tunnel (background) (~10 sec to open)

In one deploy-host shell, foreground the tunnel:

```bash
JUMPBOX_ID=$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
  --stack-name cf-migration-jumpbox \
  --query "Stacks[0].Outputs[?OutputKey=='JumpboxInstanceId'].OutputValue" \
  --output text)
echo "Jumpbox: $JUMPBOX_ID"

aws --profile ZoningInfoAdmin ssm start-session \
  --target "$JUMPBOX_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com"],"portNumber":["3306"],"localPortNumber":["3306"]}'
```

This blocks — leave it running. Output looks like:
```
Starting session with SessionId: ...
Port 3306 opened for sessionId ...
Waiting for connections...
```

**Run pgloader inside a tmux session** (the one we set up on the
deploy-host) so the tunnel and the pgloader window can both stay alive
while you work. Or use two separate SSM sessions to the deploy-host —
sessions don't share state but they share the host.

Verify the tunnel works (from a second deploy-host shell):

```bash
# IMPORTANT: use 127.0.0.1, NOT localhost. The mysql CLI treats "localhost"
# as a special token meaning "skip TCP, use UNIX domain socket" — which
# fails with ERROR 2002 (HY000) "Can't connect to local MySQL server
# through socket /var/run/mysqld/mysqld.sock" regardless of whether the
# tunnel is up. Use the IP literal to force TCP.
mysql -h 127.0.0.1 -P 3306 -u worxco -p -e "SHOW DATABASES;" zinew
# Should print the same DB list as if you ran it on the jumpbox in step 3.
```

If you get "ERROR 2003 Can't connect to MySQL server on '127.0.0.1'" —
the tunnel isn't actually established. Check the first shell for the
"Waiting for connections..." line; if the SSM session died, restart it.

If you get "ERROR 2002 ... socket /var/run/mysqld/mysqld.sock" — you
typed `localhost` instead of `127.0.0.1`. Same error every time, has
nothing to do with the tunnel. Use the IP.

### 6. Run pgloader: MySQL (localhost via tunnel) → PostgreSQL (sandbox RDS) (~depends on DB size)

In the second deploy-host shell:

```bash
# Pull sandbox PG connection details from the env file
source /etc/worxco/envs/sandbox     # provides DRUPAL_DB_HOST, _PORT, _NAME, _USER, _PASS

# Write the pgloader load file. The CASTs handle Drupal-specific
# MySQL→PostgreSQL type translations that the default pgloader
# inference gets wrong:
#   - TINYINT(1) → BOOLEAN (Drupal uses these for true/false flags)
#   - zero dates ('0000-00-00') → NULL (MySQL allows, PostgreSQL doesn't)
#   - DATETIME → TIMESTAMPTZ (PostgreSQL's timezone-aware variant)
# Password is embedded in the file — chmod 600 immediately, delete
# after the run.
read -s -p "Prod MySQL password for user 'worxco': " PROD_PW
echo
cat > /tmp/zinew.load <<EOF
LOAD DATABASE
  FROM      mysql://worxco:${PROD_PW}@127.0.0.1:3306/zinew
  INTO      postgresql://${DRUPAL_DB_USER}:${DRUPAL_DB_PASS}@${DRUPAL_DB_HOST}:${DRUPAL_DB_PORT}/${DRUPAL_DB_NAME}

WITH include drop, create tables, create indexes, reset sequences, foreign keys,
     downcase identifiers, batch rows = 1000, prefetch rows = 1000

CAST type tinyint when (= 1 precision) to boolean drop typemod using tinyint-to-boolean,
     type datetime to timestamptz drop default drop not null using zero-dates-to-null,
     type date drop not null drop default using zero-dates-to-null,
     type timestamp drop default drop not null using zero-dates-to-null
;
EOF
chmod 600 /tmp/zinew.load
unset PROD_PW

# Run it
pgloader /tmp/zinew.load 2>&1 | tee /tmp/zinew-pgloader.log

# Cleanup the password file IMMEDIATELY after the run completes
shred -u /tmp/zinew.load
```

pgloader prints a summary at the end: tables read, rows loaded,
errors, total time. Save the log (`/tmp/zinew-pgloader.log`) — you'll
want to inspect it after the first run for cast warnings.

### 7. Codebase rsync from React2 → S3 (~few min, depends on size)

This step still uses the S3 ferry. Switch to a jumpbox shell (open a
new `make ssm-migration-jumpbox` from your Mac, or use a second tmux
window in the existing session):

```bash
# rsync to local /tmp first (lets rsync resume cleanly on transient blips)
sudo rsync -av --delete \
  ubuntu@172.31.23.46:/var/www/zinew/ \
  /tmp/zinew-codebase/

# Tar + gzip + ship to sandbox S3 in one streaming pipe
sudo tar -C /tmp -cf - zinew-codebase \
  | pigz \
  | sudo aws s3 cp - s3://sandbox-migration-kv-worxco/zinew-codebase-$(date -u +%Y%m%d-%H%M%S).tar.gz

# Optional: clean up local copy on the jumpbox
sudo rm -rf /tmp/zinew-codebase
```

Adjust the source path (`/var/www/zinew/`) to wherever Drupal actually
lives on React2.

### 8. Pull codebase tarball to deploy-host and extract onto FSx (~few min)

Back on the deploy-host (any shell):

```bash
# List what's in the migration bucket
aws s3 ls s3://sandbox-migration-kv-worxco/

# Pull the most recent codebase tarball (substitute the timestamp)
aws s3 cp s3://sandbox-migration-kv-worxco/zinew-codebase-YYYYMMDD-HHMMSS.tar.gz /tmp/

# FSx should already be mounted (use-env did this for the env)
sudo use-env sandbox    # idempotent; ensures /var/www and /etc/nginx/shared mounted

# Extract into Drupal's location on FSx
sudo tar -xzf /tmp/zinew-codebase-YYYYMMDD-HHMMSS.tar.gz -C /tmp/
sudo rsync -av --delete /tmp/zinew-codebase/ /var/www/drupal/

# Re-apply Drupal-writable directory perms (see install-drupal.sh for
# the canonical set; the key ones are:)
sudo chown -R root:www-data /var/www/drupal/web/sites/default/files
sudo chmod -R u=rwX,g=rwX,o= /var/www/drupal/web/sites/default/files
```

### 9. Verify the migrated site (~2 min)

```bash
# drush status against the migrated DB
cd /var/www/drupal
sudo -E HOME=/root vendor/bin/drush status

# Then the standard smoke tests, from your Mac in the cf-scalable-drupal repo:
make smoke-test-drupal ENV=sandbox
make smoke-test-public ENV=sandbox
```

### 10. Cleanup when migration testing is done

```bash
# Order matters: destroy the prod jumpbox FIRST (so the bucket policy's
# referenced Principal is gone), THEN the bucket.
make destroy-migration-jumpbox CONFIRMED=yes
make destroy-migration-bucket CONFIRMED=yes
```

On the deploy-host:
```bash
# Remove the ZoningInfoAdmin profile credentials
rm ~/.aws/credentials
# (or open it and delete just the [ZoningInfoAdmin] block)

# Remove session-manager-plugin (optional — it's harmless to leave installed)
sudo dpkg -r session-manager-plugin
```

On React2 (via your existing SSH):
```bash
# Remove the jumpbox pubkey from authorized_keys
sed -i '/root@cf-migration-jumpbox/d' /home/ubuntu/.ssh/authorized_keys
```

## Things to watch for

- **pgloader memory pressure on large tables.** pgloader buffers
  `batch rows` rows per table at a time (1000 in the load file above).
  If you see OOM kills on the deploy-host during pgloader runs, drop
  `batch rows = 500` or `250`. Trade-off is slower load.
- **SSM session timeouts.** A port-forwarding session that's idle for
  >30 min may be terminated by AWS. If the pgloader run pauses (e.g.,
  index build on a huge table), monitor the tunnel shell — if it
  exits, re-run step 5. pgloader will pick up cleanly on a re-run
  since `include drop` recreates tables from scratch.
- **Drupal version drift.** If React2's Drupal core differs from what
  we install in sandbox (we currently bake Drupal 11), the imported
  schema won't match the codebase. Confirm core version on React2 via
  `drush status` BEFORE the migration. If mismatch: either downgrade
  sandbox to match (php74 ASG, older Drupal), or plan a
  schema-upgrade step after import.
- **Charset / collation surprises.** Aurora MySQL 8.0's default
  charset may emit warnings from pgloader. Most common fix is adding
  `--from-encoding utf8mb4` or specifying the collation in the load
  file's `WITH` clause. Inspect `/tmp/zinew-pgloader.log` after the
  first run.
- **`localhost` vs `127.0.0.1`.** The MySQL command-line client
  treats `-h localhost` as "use the UNIX socket at
  `/var/run/mysqld/mysqld.sock`" regardless of TCP listeners. With
  no local mysqld running, that fails with ERROR 2002 every time.
  Always use the IP literal (`127.0.0.1`) for the MySQL CLI when
  hitting the tunnel. pgloader URLs are TCP-by-default but we use
  the IP there too for consistency.
- **Password in the load file.** It's there for the duration of the
  pgloader run only. `chmod 600` immediately after writing it,
  `shred -u` immediately after the run. Don't `cat /tmp/zinew.load`
  to inspect — it has the password.
- **S3 codebase tarball lifecycle.** The bucket expires objects after
  30 days. For longer retention, pull them out before then.

## Why this design

- **Cross-account via SSM, not VPC peering.** Peering would require
  routing-table + SG changes that persist beyond the migration. SSM
  tunnel is established and torn down per session.
- **Jumpbox in same subnet as React2 (subnet-85e938dc).** Free SSH
  and free RDS access via existing SG rules; zero modifications to
  prod SGs.
- **Live pgloader instead of mysqldump-to-file.** pgloader has no
  mysqldump-file mode; spinning up a transient MySQL on the
  deploy-host to feed it from a dump file is more moving parts than
  the SSM tunnel.
- **Bucket policy restricts to a role-name PATTERN.** Even though
  the policy's Principal is the prod account, the
  `aws:PrincipalArn` condition means only the jumpbox role can
  actually write. If the jumpbox is destroyed and someone tries to
  write from a different prod role, the bucket rejects it.
- **Credentials on the deploy-host instead of cross-account
  assume-role.** Practical trade-off for one-time migration work.
  The deploy-host is itself ephemeral and SSM-only-access; risk
  envelope of static creds living on it is acceptable. For
  recurring migration work, switch to assume-role.

## Open questions to resolve on first run

- [ ] Drupal core version on React2 → drives whether we land in
      sandbox as the same version (php74 ASG) and upgrade after, or
      stage the schema upgrade as part of the migration.
- [ ] PHP version on React2 → confirms or refutes the Drupal-version
      inference.
- [ ] DB size + table count → sets expectations for pgloader
      runtime + memory pressure.
- [ ] Whether site-specific config files reference absolute paths
      that need translation when moving from React2's filesystem to
      FSx (`/var/www/drupal` is canonical in sandbox).

These need human judgment after first inspection; captured here so
they're not forgotten.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
