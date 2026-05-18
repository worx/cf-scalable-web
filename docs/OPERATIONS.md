# Operations Runbook

Common day-to-day operational procedures for cf-scalable-drupal.
This document covers **the things you actually do during a working session**,
not the one-time-setup story (see `README.md` and `docs/DEPLOY-HOST.md`
for those). Lessons captured from real debug sessions in 2026-04 → 2026-05.

---

## Quick command reference

These all take `ENV=<env>` (default `sandbox`):

| Command | What it does |
|---|---|
| `make check-drift` | Flag CFN templates committed in git but not yet deployed to AWS |
| `make build-amis` | Trigger all 3 Image Builder pipelines AND wait for AVAILABLE (~15-20 min) |
| `make build-amis-async` | Same, but return immediately (fire-and-forget) |
| `make wait-amis` | Poll Image Builder until all 3 pipelines reach a terminal state |
| `make update-ami-params` | Write the latest AMI IDs to SSM for all 3 pipelines |
| `make deploy-compute` | Roll updates into the compute stack (ASG launch templates) |
| `make restart-php-fpm` | SSM-exec `systemctl restart php-fpm` across every PHP box |
| `make clear-drupal-cache` | Wipe the FSx compiled container + TRUNCATE cache_* tables |
| `make pause-compute` / `resume-compute` | ASG capacity 0 (cost saver) and back |

On the deploy-host:

| Command | What it does |
|---|---|
| `sudo use-env <env>` | Switch the active environment (umount + remount FSx) |
| `sudo use-env none` | Unmount FSx, leave deploy-host idle |
| `sudo use-env` | Print current state without changing anything |
| `sudo refresh-env-config <env>` | Re-resolve env endpoints from SSM into `/etc/worxco/envs/<env>` |
| `info-env <env>` / `show-env <env>` | Live vs cached endpoint summary |
| `psql-env <env>` | Open a psql shell against the env's RDS as the master user |
| `valkey-env <env> PING` | Probe the env's ElastiCache Valkey |

---

## Common procedures

### Check for pending deploys before doing anything else

Run this at the start of any operations session. It's the cheapest way to
discover that someone (you, last week, etc.) committed a template change
that never made it to AWS:

```bash
make check-drift ENV=sandbox
```

Exit code 1 if anything is DRIFT or UNCOMMITTED. Treats UNCOMMITTED as a
sign that you need to commit before deploying (so the audit trail is clean).

**Known limitation:** doesn't check `cloudformation/parameters/*.json`
changes — RecipeVersion bumps don't show as drift until a downstream
template re-references them.

### Rebuild AMIs end-to-end

When `image-builder/configs/*` or the component code in
`cloudformation/cf-image-builder.yaml` has changed and you need fresh
AMIs across the fleet:

```bash
# Bump RecipeVersion in cloudformation/parameters/image-builder-sandbox.json
# (commit + push first if you haven't)

make upload-build-configs ENV=sandbox     # syncs image-builder/configs/ to S3
make deploy-image-builder ENV=sandbox     # registers new component versions

make build-amis ENV=sandbox               # ~15-20 min — blocks until AVAILABLE
                                          # tail-friendly: prints per-pipeline
                                          # status every 30s

make update-ami-params ENV=sandbox        # write new AMI IDs to SSM
make deploy-compute ENV=sandbox           # update launch templates

# Roll the fleet onto the new AMIs
for ASG in sandbox-nginx-asg sandbox-php74-asg sandbox-php83-asg; do
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG" \
    --strategy Rolling \
    --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120,"SkipMatching":true}'
done
```

**Why `build-amis` blocks now:** the previous fire-and-forget behavior
caused a silent race — chained `update-ami-params` would find the
**previous** AVAILABLE AMI (because the new one wasn't built yet) and
write that to SSM, so `deploy-compute` rolled to the same AMI we already
had. Made `make deploy-all` look successful while changing nothing.

### Restart PHP-FPM across the fleet

After editing `settings.php` on FSx (PHP's OPcache otherwise serves stale
PHP), after rotating a secret that's exposed via PHP-FPM `env[]`, or any
time workers need to re-read pool config without a full instance cycle:

```bash
make restart-php-fpm ENV=sandbox
```

SSM-execs `systemctl restart php<ver>-fpm` on every InService instance
in both `<env>-php74-asg` and `<env>-php83-asg`. Returns a status table
per instance.

### Clear Drupal cache (both layers)

Drupal caches its compiled service container in TWO places:
- **Filesystem**: `/var/www/drupal/web/sites/default/files/php/` on FSx
- **Database**: `cache_container`, `cache_bootstrap`, `cache_discovery`,
  and other `cache_*` tables in PostgreSQL

If you wipe only one layer, the other repopulates the broken state on
the next request. `make clear-drupal-cache` wipes both:

```bash
make clear-drupal-cache ENV=sandbox
```

Orchestrates via SSM through the deploy-host (the only host with both
FSx mounted AND `psql-env` credentials). **Refuses to run if the
deploy-host's `current-env` doesn't match the requested env** — so you
can't accidentally wipe staging while sandbox is active.

After cache wipe, typically also:
```bash
make restart-php-fpm ENV=sandbox     # bust OPcache
```

### Switch the deploy-host between environments

The deploy-host operates on one env at a time. The active env is recorded
in `/etc/worxco/current-env` and shown right-aligned on every zsh prompt
as `[env:<name>]`:

```bash
sudo use-env sandbox      # mount sandbox FSx at /var/www
sudo use-env staging      # unmount, mount staging FSx instead
sudo use-env none         # unmount, leave deploy-host with no env active
sudo use-env              # show current state without changing anything
```

The zsh wrapper (in `/etc/zsh/zshrc.d/worxco-prompt.zsh`) sources
`/etc/worxco/envs/<env>` into your current shell after a successful
switch so `$DRUPAL_DB_HOST` etc. are available immediately.

### Rotate the Drupal DB password

When the auto-generated password ends up with chars that downstream
tooling can't handle, or as routine rotation:

```bash
# From the deploy-host (uses master creds via psql-env)
NEW_PASS=$(aws secretsmanager get-random-password --password-length 32 \
  --exclude-characters '"@/\\'"'"'#%&+:;=?[]~$`<>*|^!(){}' \
  --region us-east-1 --query RandomPassword --output text)
echo "New password: $NEW_PASS"

# Update both sides — order matters: postgres first, then the secret.
# (If you update the secret first and then PHP-FPM picks it up before
# postgres has the new value, every request fails until ALTER USER runs.)
psql-env sandbox -c "ALTER USER drupal_user WITH PASSWORD '$NEW_PASS';"
aws secretsmanager update-secret \
  --secret-id worxco/sandbox/drupal/db-password \
  --secret-string "$NEW_PASS" \
  --region us-east-1 > /dev/null

unset NEW_PASS

# Make the new value visible to the live PHP-FPM workers
make restart-php-fpm ENV=sandbox
```

After this, `configure-php.sh` on any FRESH instance launch will read
the new secret and write it into `www.conf`. Existing workers were
busted by the `restart-php-fpm` above.

### Pause / resume compute (cost saver)

FSx is roughly 60% of the running monthly bill; the rest is mostly
compute. When sandbox is idle (overnight, weekends, between sprints):

```bash
make pause-compute ENV=sandbox     # ASGs to 0; instances terminate
make resume-compute ENV=sandbox    # ASGs back to MinSize; new instances launch
```

FSx, RDS, ElastiCache, and the deploy-host stay running — only the
auto-scaled compute (nginx + php74 + php83) is parked. State on FSx
and in RDS is preserved.

---

## Anti-patterns / things NOT to do

- **Don't `make deploy-compute` without first running `make update-ami-params`**
  if you just rebuilt AMIs. The launch templates reference SSM params; if
  the params still point at old AMIs, `deploy-compute` is a no-op.

- **Don't edit `settings.php` on FSx without running `make restart-php-fpm`**.
  PHP's OPcache will keep serving the old version until workers restart.
  We learned this twice; once should be enough.

- **Don't run `sudo umount /var/www` while your shell is `cd`'d inside it.**
  The unmount silently fails with EBUSY but the script proceeds — you end
  up with a half-unmounted state. `use-env` checks for this and refuses.

- **Don't `terminate-instance` on every PHP box at once if the runtime
  is serving traffic.** Use `start-instance-refresh` with
  `MinHealthyPercentage: 50` so the rollover is gradual.

- **Don't trust `make` exit codes to mean "AWS is done"** unless the
  target is explicitly documented as blocking. Most CFN/Image-Builder
  targets return as soon as the API call is acknowledged, not when AWS
  finishes the work. `make build-amis` (the blocking variant) is the
  exception, not the rule.

---

## Where errors show up

| Layer | Where to look |
|---|---|
| Drupal application | `sudo tail -f /var/log/php8.3-fpm.log` on a PHP box |
| PHP-FPM startup | `sudo journalctl -u php8.3-fpm` on a PHP box |
| nginx | `sudo tail -f /var/log/nginx/{error,access}.log` on an nginx box |
| Deploy-host boot | `/var/log/deploy-host-bootstrap.log` |
| AMI builds | S3: `s3://<env>-image-builder-<suffix>/build-logs/`, or Image Builder console |
| CloudFormation | `aws cloudformation describe-stack-events --stack-name <name>` |
| Recent gotchas | `docs/memory/gotchas.md` — read before reinventing the wheel |

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
