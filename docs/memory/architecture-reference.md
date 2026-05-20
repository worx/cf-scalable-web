---
name: Architecture Quick Reference
description: Key file paths, stack names, resource relationships, and deployment sequence for fast orientation
type: project
created: 2026-04-25
---
# Architecture Quick Reference

## Stack Names (ENV=sandbox)
- `cf-scalable-web-sandbox-vpc`
- `cf-scalable-web-sandbox-iam`
- `cf-scalable-web-sandbox-storage`
- `cf-scalable-web-sandbox-image-builder`
- `cf-scalable-web-sandbox-compute-alb`
- `cf-scalable-web-sandbox-compute-nlb`
- `cf-scalable-web-sandbox-compute-nginx`
- `cf-scalable-web-sandbox-compute-php`
- `cf-scalable-web-sandbox-database` (optional, runtime)
- `cf-scalable-web-sandbox-cache` (optional, runtime)
- `cf-deploy-host` (standalone, no ENV prefix)

## AWS Account
- **Sandbox**: 033879516417 (ZI-Sandbox profile, assumes OrganizationAccountAccessRole)
- **Parent/Management**: 645925380349 (worxco alias, kvanderw user)

## Deploy-All Sequence (~50 min)
1. Foundation: VPC → IAM → Storage (FSx ~15 min)
2. Image Builder: deploy stack → upload configs → trigger 3 AMI builds → poll until AVAILABLE (~25 min)
3. AMI Params: write to SSM (`/sandbox/ami/nginx`, `/sandbox/ami/php74`, `/sandbox/ami/php83`)
4. Compute: ALB → NLB → NGINX → PHP (~5 min)

## Key SSM Parameters
- `/environment/name` → sandbox
- `/${ENV}/fsx/dns-name` → FSx NFS hostname
- `/${ENV}/cache/endpoint` → Valkey hostname
- `/${ENV}/nlb/endpoint` → NLB DNS
- `/${ENV}/ami/nginx`, `/${ENV}/ami/php74`, `/${ENV}/ami/php83` → AMI IDs
- `/${ENV}/rds/endpoint` → RDS hostname (when deployed)

## Key Secrets Manager Paths
- `worxco/${env}/cache/auth-token` → Valkey AUTH
- `worxco/${env}/rds/master-password` → RDS password
- `worxco/deploy-host/github-ssh-key` → Deploy key (private + public)
- `worxco/deploy-host/root-password` → Optional root password

## Control Plane vs Data Plane (the architectural model)

The system has two roles that share the same FSx volume and RDS database but have very different network postures:

| Role | Where | What | Internet egress |
|------|-------|------|-----------------|
| **Data plane** (serves traffic) | PHP-FPM auto-scaling group in project VPC | Reads code from FSx, queries RDS, returns HTTP via NLB → NGINX → ALB | **No** — sealed by design (no NAT, no IGW route) |
| **Control plane** (manages code) | Deploy host in default VPC | Runs CloudFormation, fetches packages, writes Drupal code to FSx, runs drush | **Yes** — full egress |

**Key insight**: when the deploy host writes new Drupal code via `composer require`, every PHP-FPM instance sees it on its NFS mount immediately. No restarts, no rotation, no SSH-into-PHP. The deploy host is the *only* path through which new code enters the system, by design.

This is why the deploy host has internet access AND mounts FSx AND has VPC peering — it's the controlled, audited entry point. Day-two operations (module installs, config changes, drush operations) all run through it.

See `docs/DEPLOY-HOST.md` "Control Plane vs Data Plane" and "Day-Two Operations" sections for the full pattern.

## Deploy Host Toolchain (Phase B, post-2026-05-06)
The deploy-host UserData installs a Drupal management toolchain on every fresh
boot. Available tools (in PATH for `ubuntu` user):

- `aws`, `git`, `make`, `tmux`, `screen`, `vim`, `claude` (original toolset)
- `php` (8.3 CLI) + extensions: cli, common, curl, mbstring, xml, zip, gd, pgsql, intl, bcmath, opcache
- `composer` (latest stable, in /usr/local/bin)
- `drush` (composer global, in ~/.config/composer/vendor/bin — added to PATH via .bashrc)
- `psql` (postgresql-client, latest from Ubuntu 24.04)
- `redis-cli` (redis-tools — wire-compatible with Valkey)
- `nfs-common` (FSx mount support)
- `session-manager-plugin` (better SSM CLI experience)

### Marker file
`/etc/worxco/deploy-host-marker` — exists only on the deploy host. Scripts and
Make targets check this to detect "I'm running on the deploy host" vs "I'm on
local Mac and need to dispatch via SSM".

### Helper commands (all auto-resolve endpoints from SSM/Secrets — no manual lookups)

- `info-env <env>` — print **live** RDS, FSx, Valkey, ALB endpoints from SSM (~3-5s, network call)
- `show-env <env>` — print **cached** endpoints from `/etc/worxco/envs/<env>` (instant, no network)
- `sudo refresh-env-config [envs...]` — regenerate cache from SSM (NOPASSWD via sudoers.d, no password prompt)
- `mount-env <env>` — mount FSx OpenZFS at `/var/www/<env>` (requires sudo). Writes `/etc/fstab` entry so mount survives stop/start. bootstrap.sh auto-runs this for each deployed env on terminate/replace, so the persistence story is automatic across both lifecycle types.
- `psql-env <env> [args]` — connect to env's RDS as dbadmin (auto-fetches password from Secrets Manager)
- `valkey-env <env> [args]` — connect to env's Valkey via redis-cli (auto-fetches AUTH token, uses TLS)

### Endpoint cache files

`/etc/worxco/envs/<env>` — sourceable shell config with all endpoint variables for an environment.
Generated automatically at deploy-host boot (best-effort, skips envs with no infrastructure).
Regenerate after a destroy/redeploy with `sudo refresh-env-config <env>`. No secrets stored —
passwords stay in Secrets Manager and are fetched by the `*-env` helpers as needed.

```
source /etc/worxco/envs/sandbox    # exports RDS_ENDPOINT, FSX_DNS, VALKEY_HOST, ALB_DNS, ...
echo $RDS_ENDPOINT                  # or use directly: psql -h $RDS_ENDPOINT ...
```

Examples:
```
info-env sandbox                    # live truth
show-env sandbox                    # cached (instant)
sudo refresh-env-config sandbox     # rebuild cache after destroy/deploy
psql-env sandbox -c 'SELECT now();' # query without thinking about endpoints
valkey-env sandbox PING             # one-off Valkey
```

## Boot Script Flow (PHP instances)
1. UserData calls `/opt/worxco/configure-php.sh` (baked into AMI)
2. Script gets IMDS token → region → reads `/environment/name` from SSM
3. Mounts FSx: `mount -t nfs4 -o vers=4.1,port=2049 $FSX_DNS:/fsx /var/www`
4. Configures Valkey session handler from `/${ENV}/cache/endpoint`
5. Configures Postfix SES relay (if SES credentials exist)
6. Starts PHP-FPM and health-check NGINX (port 9100)

## Image Builder Version Bumping
When changing component content in cf-image-builder.yaml:
1. Edit the template
2. Bump `RecipeVersion` in `cloudformation/parameters/image-builder-sandbox.json`
3. `make deploy-image-builder ENV=sandbox`
4. `make upload-build-configs ENV=sandbox`
5. `make build-amis ENV=sandbox`
6. Wait for completion, then `make update-ami-param` for each pipeline
7. `make deploy-compute-nginx` + `make deploy-compute-php` (ForceUpdateToken forces re-resolution)
