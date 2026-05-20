---
name: Customization Guide — where to edit which thing
description: For engineers asking "where in the repo do I make this change?" — maps every customizable surface to its canonical source file, the apply workflow, and the audit trail expectation
audience: contributor
created: 2026-05-20
---
# Customization Guide

If you're about to change something in this stack, **read the right
row of the table below first**. The wrong edit-location is a leading
cause of "I changed it but it didn't take effect" and of changes that
get clobbered on the next deploy.

The golden rule: **everything should be infrastructure-as-code under
git.** A change that lives only on a running instance gets lost on the
next AMI rebuild, instance refresh, FSx destroy, or destroy-all. If
you find yourself making a change on a live host, the question to ask
is: "what file in the repo do I edit so the change survives a
destroy/redeploy?"

Three audiences for this doc:
- **Drupal engineers** (themes, modules, content, settings.php
  behavior) — see "Drupal application layer" below
- **Infrastructure engineers** (CFN, AMIs, networking, scaling) — see
  "Infrastructure" below
- **Operations** (day-to-day Make targets, manual fixups) — see
  `docs/OPERATIONS.md` for the runbook; this doc is about where
  things LIVE rather than how to operate them

## How to read this doc

For each customization area, the table tells you:
- **What lives where**: the canonical source file
- **How it deploys**: which Make target or workflow applies it
- **What survives**: does this change persist across destroy-all?

If a file is on FSx (not in git), assume it does NOT survive destroy-all.

---

## Infrastructure layer

These changes happen at the CloudFormation / AMI / boot-script level.
Almost always require an AMI rebuild OR a `make deploy-<stack>` to
take effect.

### Network architecture (VPC, subnets, security groups, peering, endpoints)

| Concern | Source file | Apply workflow |
|---|---|---|
| VPC CIDR + subnets (4-tier private + public) | `cloudformation/cf-vpc.yaml` | `make deploy-vpc ENV=<env>` |
| Security groups (which tier talks to which) | `cloudformation/cf-vpc.yaml` (SGs) + `cloudformation/cf-compute-*.yaml` (per-service SG rules) | `make deploy-vpc` + relevant `deploy-compute-*` |
| VPC Endpoints (SSM, Secrets Manager, S3, SES) | `cloudformation/cf-vpc.yaml` | `make deploy-vpc ENV=<env>` |
| Deploy-host VPC peering | `cloudformation/cf-deploy-peering.yaml` | `make deploy-peering ENV=<env>` |
| ALB / NLB / target groups | `cloudformation/cf-compute-alb.yaml`, `cf-compute-nlb.yaml` | `make deploy-compute-alb` / `deploy-compute-nlb` |

> **NAT Gateway**: optional knob (`EnableNATGateway` param in cf-vpc.yaml),
> defaults `false`. We deliberately don't use NAT. See
> `docs/ARCHITECTURE.md` and `docs/memory/admin-access-policy.md`.

### IAM (roles, policies, instance profiles)

| Concern | Source file |
|---|---|
| All project IAM roles + policies | `cloudformation/cf-iam.yaml` |
| Deploy-host's IAM (separate role) | `cloudformation/cf-deploy-host.yaml` |

Apply with `make deploy-iam ENV=<env>` (or `deploy-deploy-host` for the
deploy-host's role specifically).

**Common change: "X needs read access to Y SSM param / Secret."** Edit
the relevant role in `cf-iam.yaml` (or `cf-deploy-host.yaml`), add the
ARN to the role's policy, redeploy. The Drupal-secrets path
`worxco/<env>/drupal/*` is already covered by the compute roles.

### AMI contents (what's baked into compute instances)

The fleet runs from custom AMIs built by EC2 Image Builder. Editing
runtime behavior of nginx/PHP usually means editing the AMI recipe and
re-baking.

| Concern | Source file | Triggers |
|---|---|---|
| Base OS hardening (apt updates, SSH config, sysctl) | `image-builder/components/base-hardening.yaml` + inline blocks in `cloudformation/cf-image-builder.yaml` | bump `RecipeVersion` in `cloudformation/parameters/image-builder-<env>.json`, `make deploy-image-builder`, `make build-amis`, `make update-ami-params`, `make deploy-compute` |
| nginx install + base nginx.conf (header, gzip, log format) | `cloudformation/cf-image-builder.yaml` NginxInstallComponent + `image-builder/configs/nginx/nginx.conf` (this gets pulled from S3 at AMI bake) | `make upload-build-configs`, then the rebuild chain |
| PHP-FPM install + base www.conf | `cloudformation/cf-image-builder.yaml` PhpFpm{74,83}InstallComponent | rebuild chain |
| Boot scripts on AMI (configure-php.sh, configure-nginx.sh) | `cloudformation/cf-image-builder.yaml` inline CreateBootScript steps + `image-builder/configs/configure-php.sh` | rebuild chain |
| Which Ubuntu LTS the AMI is based on | `cloudformation/cf-image-builder.yaml` ParentImage (3 places, one per pipeline) + `image-builder/components/install-nginx.yaml` codename refs | rebuild chain. See `docs/memory/ubuntu-version-decision.md` for the upgrade playbook. |

> The `image-builder/components/*.yaml` files are **reference copies**
> for documentation. The canonical install code lives inline in
> `cf-image-builder.yaml`. Touching the components-yaml does not affect
> AMI builds — touch the CFN template.

### Compute fleet behavior (per-boot configuration on every instance)

| Concern | Source file |
|---|---|
| PHP boot configuration (write `env[]` + Valkey session URL to www.conf) | `image-builder/configs/configure-php.sh` (lives in S3, fetched at boot) |
| NGINX boot configuration (mount FSx, write upstream-php.conf) | inline in `cloudformation/cf-image-builder.yaml` (CreateBootScript) |
| ASG launch templates (instance type, IMDSv2 settings, user data) | `cloudformation/cf-compute-nginx.yaml`, `cf-compute-php.yaml` |
| Auto-scaling policies (target tracking, max lifetime) | `cloudformation/cf-compute-nginx.yaml`, `cf-compute-php.yaml` |

**Common change pattern**: edit boot script in `image-builder/configs/`,
`make upload-build-configs ENV=<env>` to sync S3, **bump RecipeVersion**
in `image-builder-<env>.json`, run the rebuild chain. Existing
instances don't see the change until they're refreshed.

### Storage

| Concern | Source file |
|---|---|
| FSx OpenZFS configuration (capacity, throughput, snapshots) | `cloudformation/cf-storage.yaml` |
| S3 buckets (image-builder configs, future media/backups) | `cloudformation/cf-storage.yaml` |
| FSx directory layout (drupal/, drupal-private/, drupal-config/, nginx/, sites/<slug>/) | `scripts/deploy-host/install-drupal.sh` (creates dirs) + `scripts/init-fsx-layout.sh` (pre-creates `/fsx/nginx/sites-enabled` + `/fsx/sites` before compute boots). **The authoritative spec is [docs/FSX-LAYOUT.md](FSX-LAYOUT.md)** — keep edits in sync. |

### Data layer (RDS, Valkey)

| Concern | Source file |
|---|---|
| RDS PostgreSQL config (instance class, parameter group, backups) | `cloudformation/cf-database.yaml` |
| ElastiCache Valkey config (node count, AUTH, TLS) | `cloudformation/cf-cache.yaml` |
| Per-env RDS/Valkey sizing parameters | `cloudformation/parameters/<stack>-<env>.json` |

Apply with `make deploy-database` / `make deploy-cache`.

### Image Builder / AMI build pipeline

| Concern | Source file |
|---|---|
| Image Builder infrastructure + recipes | `cloudformation/cf-image-builder.yaml` |
| Recipe versions (must bump on every meaningful change) | `cloudformation/parameters/image-builder-<env>.json` |
| Build configs synced to S3 at deploy time | `image-builder/configs/` (synced by `make upload-build-configs`) |

---

## Drupal application layer

These are the changes Drupal engineers reach for first. As of
2026-05-20, single-site Drupal lives at `/var/www/drupal/` on FSx.
Most application-layer changes are persisted in **Drupal's database
+ codebase** rather than in CFN. The future multi-tenant model
(see `docs/plans/multi-tenancy.md`) replaces composer-on-FSx with
per-site git overlays — that's the right place to land code-shaped
customizations long-term.

### Drupal codebase (modules, themes, composer dependencies)

**Today** (single-site, composer install on FSx during install-drupal):
- Codebase materializes at `/var/www/drupal/` on FSx via
  `scripts/deploy-host/install-drupal.sh` → `composer create-project drupal/recommended-project`
- After install, you CAN ssh/ssm-session-manager into the deploy-host
  and `composer require drupal/some_module` from `/var/www/drupal/`
- BUT: those changes live only on FSx. destroy-all wipes them. **They
  are not in git.** They are not audit-trailed.

**Future / recommended pattern** (per `docs/plans/multi-tenancy.md`):
- A `worxco-drupal-base` repo holds shared Drupal composer.json +
  base modules + base theme
- One `worxco-drupal-site-<slug>` repo per site, depending on the
  base via composer VCS
- install-drupal becomes `composer install` from the site repo, not
  `composer create-project`
- Custom modules + themes live in those git repos
- destroy/redeploy = `composer install` from current HEAD → same
  code reproducibly

If you need to customize Drupal code TODAY, the path is rough — there's
no per-site repo yet. The honest answer is: capture what you need as
a TODO and we'll wire it up properly when we go multi-tenant.

### settings.php behavior (trusted_host_patterns, file paths, env-var-driven config)

| Concern | Where to edit |
|---|---|
| settings.php content template | `scripts/deploy-host/install-drupal.sh` (the heredoc that writes settings.php) |
| trusted_host_patterns (which hostnames Drupal accepts) | install-drupal.sh's `$settings['trusted_host_patterns']` block. Currently includes localhost, 127.0.0.1, `*.elb.amazonaws.com`, and `$DRUPAL_SITE_NAME` if env-set. |
| Which env vars settings.php reads | install-drupal.sh + `image-builder/configs/configure-php.sh` (which writes the `env[]` block into www.conf) |

After editing install-drupal.sh: `make reinstall-drupal-remote` (full
wipe + reinstall) or surgically with `make install-drupal-remote` (if
the install marker isn't present).

### nginx vhost (per-site web server config)

| Concern | Where to edit |
|---|---|
| nginx vhost template (`server { listen 80 default_server; ... }`) | `scripts/deploy-host/install-drupal.sh` AND `scripts/publish-drupal-vhost.sh` — **two copies kept in sync** (one for fresh install, one for surgical re-publish). |
| Vhost on the running fleet | `/var/www/nginx/sites-enabled/drupal.conf` on FSx — written by either of the two scripts above |
| Apply a vhost change without reinstalling Drupal | `make publish-drupal-vhost ENV=<env>` (writes new vhost to FSx) + `make reload-nginx ENV=<env>` (fleet picks it up) |

### PHP runtime config (php.ini overrides, php-fpm pool settings)

| Concern | Where to edit |
|---|---|
| PHP version selection per host | `image-builder/configs/configure-php.sh` (reads `/opt/worxco/php-version`) |
| www.conf base settings (pm, listen, logging) | inline in `cloudformation/cf-image-builder.yaml` (PHP install component) |
| env[] block in www.conf (DB credentials, SITE_NAME, etc.) | `image-builder/configs/configure-php.sh` (writes the marker block at boot) |
| PHP extensions installed | `cloudformation/cf-image-builder.yaml` PHP install component |

After PHP boot-script changes: `make upload-build-configs` syncs to
S3, then **either** rebuild AMIs **or** for live boxes, SSM-dispatch
a re-run of `/opt/worxco/configure-php.sh` + `make restart-php-fpm`.

### Drupal admin UI changes (content, content types, views, fields, blocks)

This is the "Drupal site builder" surface. Changes made through the
admin UI live in the **database**, not in git.

For audit trail + reproducibility:
- Drupal's **config sync** workflow: `drush config:export` → writes
  YAML to `/var/www/drupal-config/` (on FSx). Import on a new env
  with `drush config:import`.
- This is the right way to move "I made these changes in the UI" from
  one environment to another reproducibly. The exported YAML CAN go
  into a per-site git repo (multi-tenant pattern).

Today's single-site model doesn't have a per-site git repo to commit
exports to. Treat `/var/www/drupal-config/` as the canonical state
for now; commit it to a per-site repo as soon as we go multi-tenant.

### Themes + CSS

| Concern | Where to edit (today) | Where to edit (multi-tenant future) |
|---|---|---|
| Site theme selection (e.g., Olivero vs custom) | Drupal admin UI (lives in DB) | `worxco-drupal-site-<slug>` repo's `composer.json` + `config/sync/` |
| Theme files (templates, .info.yml, CSS, JS) | `/var/www/drupal/web/themes/custom/<theme>/` on FSx — NOT IN GIT | Inside the per-site repo at `web/themes/custom/<theme>/` |
| CSS aggregation behavior (preprocess on/off) | Drupal admin UI → Performance, OR `drush config:set system.performance css.preprocess 1` | Same, persisted via config:export |

The unstyled-page bug we hit today (2026-05-20) was an
infrastructure-side issue (nginx wasn't routing aggregate URLs to PHP)
not a Drupal-theme issue. See `docs/memory/gotchas.md`.

### Drupal secrets (DB password, admin password, hash_salt)

| Secret | Where it lives | How to rotate |
|---|---|---|
| Drupal admin password | Secrets Manager `worxco/<env>/drupal/admin-password` (owned by cf-app-drupal) | Update the secret; `make install-drupal-remote` re-syncs (or use drush `user:password admin <new>`) |
| Drupal DB user password | Secrets Manager `worxco/<env>/drupal/db-password` (owned by cf-app-drupal) | Update the secret + ALTER USER on postgres + restart PHP-FPM (so env[] reload). `docs/OPERATIONS.md` has the runbook. |
| Drupal hash_salt | **Currently FSx-only** at `/var/www/drupal-private/salt.txt`. Will move to SSM SecureString — see `docs/memory/salt-persistence-design.md` for the design + TODO P1. | Today: regenerate by deleting the file + re-running install-drupal. Will be `make rotate-salt` once SSM-backed. |
| RDS master password | Secrets Manager `worxco/<env>/rds/master-password` (owned by cf-database) | Update via AWS console / CLI; install-drupal handles re-sync to the drupal user |
| Valkey AUTH token | Secrets Manager `worxco/<env>/cache/auth-token` (owned by cf-cache) | Rotate, then `make restart-php-fpm` |

### Drupal Make-target reference

The full list of operational targets lives in `docs/OPERATIONS.md`.
The most commonly-invoked Drupal-specific ones:

```
make install-drupal-remote ENV=<env>    # full install via deploy-host
make publish-drupal-vhost ENV=<env>     # nginx vhost only (no reinstall)
make reload-nginx ENV=<env>             # pick up vhost changes
make restart-php-fpm ENV=<env>          # bust OPcache; reload env vars
make clear-drupal-cache ENV=<env>       # FSx compiled container + DB cache_* tables
make smoke-test-drupal ENV=<env>        # curl ALB, assert HTTP 200
make endpoints ENV=<env>                # ALB URL, admin login, all relevant endpoints
```

---

## Cross-cutting: where do things you change persist?

Quick reference table for "if I change X, what happens on destroy-all?"

| Change location | Survives destroy-all? | Survives instance refresh? |
|---|---|---|
| CFN template in `cloudformation/` (committed to git) | ✅ — definition lives in git; resources rebuild from template | ✅ — instance refresh just re-launches from existing template |
| Boot script in `image-builder/configs/` (committed + S3) | ✅ — script lives in git AND S3; new boots fetch from S3 | ✅ — new instances run the current script at boot |
| File on FSx via composer/drush install of Drupal code | ❌ — FSx destroyed by destroy-all | ✅ — FSx is shared, instances mount the same data |
| File written manually to a running EC2 instance | ❌ — wiped on instance refresh (7-day max lifetime) | ❌ — gone on next refresh |
| Secret in Secrets Manager | ✅ — Secrets Manager NOT touched by destroy-all (lives in cf-app-drupal which destroy-all explicitly preserves) | ✅ — instance role reads at boot, no instance-side state |
| SSM Parameter | ✅ — parameters survive destroy-all | ✅ — same |
| Drupal database content (nodes, users, config in DB) | ❌ — RDS destroyed by destroy-all | ✅ — DB survives instance refresh |
| Drupal config-sync YAML on FSx | ❌ — FSx destroyed by destroy-all | ✅ — FSx shared |

**Bottom line for audit trail**: anything you want to survive
destroy-all MUST be in git (CFN templates, boot scripts) OR in
Secrets Manager / SSM Parameter Store. FSx is "ephemeral working
state" by destroy-all's design.

The multi-tenant per-site git repo pattern (multi-tenancy.md) closes
the gap for Drupal modules/themes/config that today live only on FSx.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
