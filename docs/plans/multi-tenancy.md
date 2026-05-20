---
name: Multi-Tenancy and Drupal Site Lifecycle Plan
description: Target architecture for evolving cf-scalable-web from single-site-per-env to true multi-tenant Drupal hosting
audience: all
created: 2026-05-08
---
# Multi-Tenancy and Drupal Site Lifecycle Plan

**Status**: Planning — deferred. Target architecture; not active work.
**Last revision**: 2026-05-20 (path-layout direction change, secret-propagation
mechanism, three-zone backup model).
**Target Implementation**: After Phase C (single-site cloud install) is
complete and validated.

## Purpose

This document captures the architectural decisions and constraints for
evolving the cf-scalable-web infrastructure from a single-Drupal-site-per-
environment model into a true multi-tenant Drupal hosting platform.

It also documents the operational model that surfaces during multi-tenant
deployments — who has access to what, what flows through which channel,
and what the platform deliberately does NOT expose.

This is **not a near-term work item**. Phase C (single-site cloud
install) must be complete and validated first. Treat this as a target
architecture and a checklist of design constraints to keep in mind
during current work.

> **Related reading**: [docs/FSX-LAYOUT.md](../FSX-LAYOUT.md) is the
> authoritative reference for the FSx directory structure, file
> ownership, and the per-site config-propagation mechanism. This doc
> covers the *application-layer* lifecycle (sites, codebase, repos,
> upgrades); FSX-LAYOUT covers *where things sit on disk* and *how
> they propagate at runtime*.

## Two Deployment Models

The same infrastructure code base supports two very different customer
types, and the multi-tenancy story has to work for both.

### Model A: Managed Hosting (worxco)

The Worx Company owns the AWS account, deploys the infrastructure, and
hosts many clients' Drupal sites on it.

- **Account ownership**: worxco
- **Many tenants per environment**: each client = one or more sites
- **Tenant isolation needs**: hostnames, databases, codebases — per client
- **Platform operators**: worxco staff manage all infrastructure-layer work
- **Module/codebase changes**: clients request, worxco IT performs
- **Existing production system**: already runs four PHP versions
  concurrently for tenant compatibility (clients on older versions who
  haven't paid to upgrade)
- **Billing**: centralized through worxco; clients pay worxco

### Model B: Self-Managed (corporate IT)

A larger organization owns their own AWS account and deploys the
infrastructure to host their own portfolio of websites.

- **Account ownership**: the customer organization
- **Multiple tenants per environment**: typically the org's own brands,
  divisions, or product sites — not external clients
- **Tenant isolation needs**: same as Model A, but boundary is between
  internal divisions rather than external clients
- **Platform operators**: customer's internal IT team
- **Module/codebase changes**: requested by content owners, performed by IT
- **Billing**: directly from AWS to the customer; worxco may consult or operate

The infrastructure code is identical across both models. The
differences are purely in *who* operates the platform and *who* owns
the AWS account.

## Three Roles, Three Channels

In both deployment models, the same three-tier operational structure applies:

| Role | Examples | Has access to | Does NOT have access to |
|------|----------|---------------|-------------------------|
| **End User** | Content editors, marketing, communications | Drupal admin UI for content, media, basic config (their own site only) | OS, FSx, RDS, secrets, deploy-host, CloudFormation, modules |
| **IT Operator** | worxco staff (Model A); customer IT (Model B) | Deploy-host (SSM), `drush`, `composer`, FSx, all sites' admin UI | AWS account changes outside the project, IAM, network config |
| **Platform Team** | worxco infrastructure team | Full AWS account, CloudFormation, IAM, all secrets | (no restriction — they own the system) |

**Key principle**: end users *never* touch infrastructure. Module
installs and codebase changes always flow through the IT operator role.
This is enforced by the architecture — end users have only HTTP access
via the ALB; they don't have SSM, SSH, or any path to FSx or RDS.

This is why the deploy-host's "control plane" role matters so much (see
`docs/DEPLOY-HOST.md`). It's the *only* path for module changes, and
access to it is gated by AWS IAM + SSM Session Manager — auditable,
compliance-friendly, and keeps end users firmly in their lane.

## Environment isolation: enforced by AWS resources, not paths

**Each environment gets its own dedicated FSx, RDS, and Valkey.**
Environments share nothing — a test process gone wrong in sandbox
cannot affect staging or production at the data-layer level. This
isolation is the *point* of the per-env stack architecture.

A consequence of this design: **`<env>` never appears in any FSx-internal
path, secret path, or SSM parameter that lives on FSx.** The env is
encoded by *which AWS resource is in use*, not by directory naming.

This is a reversal of an earlier draft of this document, which said
"keep `<env>` in the path." That guidance was based on the assumption
that one FSx would be shared across envs with subfolder-level
separation. We rejected that model in favor of full-resource-per-env
isolation (cutover commit ee319d5, 2026-05-15), and this doc now
reflects that.

What that means for paths:

| Surface | Before (rejected) | Current target |
|---|---|---|
| Drupal docroot | `/var/www/<env>/sites/<slug>/drupal/web` | `/var/www/sites/<slug>/drupal/web` |
| FSx layout | `/fsx/<env>/...` | `/fsx/...` (the volume is already env-scoped) |
| SSM (AWS API path) | `/<env>/drupal/*` | `/<env>/sites/<slug>/*` — env stays in SSM paths because SSM is account-global; per-site segment is the new addition |
| Secrets Manager | `worxco/<env>/drupal/*` | `worxco/<env>/sites/<slug>/*` — same: env stays in account-global API paths; site segment is added |

SSM and Secrets Manager APIs are account-global, so they keep an env
segment to disambiguate. FSx is per-env at the volume level, so it
doesn't need one in the path.

For the full FSx directory structure, see
[docs/FSX-LAYOUT.md](../FSX-LAYOUT.md).

## What Multi-Tenancy Changes

Today's `install-drupal.sh` assumes "one site per environment".
Multi-tenancy means many sites per environment. Here's what changes:

| Aspect | Current (single-site) | Multi-tenant target |
|--------|----------------------|---------------------|
| **Path** | `/var/www/drupal/` | `/var/www/sites/<site-slug>/drupal/` |
| **Database name** | `drupal` (one per env's RDS) | `drupal_<site-slug>` (all in same env's RDS) |
| **DB user** | `drupal_user` | `drupal_<site-slug>_user` |
| **Hostname** | one (e.g., `drupal-sandbox.test`) | many (`client1.example.com`, `client2.com`, ...) |
| **PHP version** | one per env | per-site (NLB foundation exists; ports 9074, 9080, 9083) |
| **Secrets path** | `worxco/<env>/drupal/*` | `worxco/<env>/sites/<site-slug>/*` |
| **SSM params** | `/<env>/drupal/*` | `/<env>/sites/<site-slug>/*` |
| **Config delivery to PHP** | `env[]` in `www.conf` at boot | per-site `site-meta.yml` on FSx + Secrets Manager at request time (see FSX-LAYOUT.md) |
| **NGINX config** | one server block | per-site server block + `default_server` 404 fallback |
| **CFN stack (app layer)** | one `cf-app-drupal-<env>` | one `cf-app-drupal-<env>-<site-slug>` per site |
| **Make targets** | `make install-drupal ENV=sandbox` | `make install-site SITE=client1 ENV=sandbox PHP=83 DOMAIN=client1.com` |

The NLB and port-based PHP-version routing already exists in
`cf-compute-nlb` — that foundation does not need to be redesigned.
The work is in the application/management layer: scripts, NGINX config,
settings.php, and the lifecycle stack.

## Per-site config delivery and propagation

**Critical mechanism**: site config (including secrets) must propagate
to running PHP-FPM workers **without requiring restarts**. The
single-site model (env[] in www.conf at boot) does not scale to
multi-tenant — adding a site, rotating a password, or changing site
config cannot require a fleet-wide PHP-FPM restart for each change.

The design: per-site config on FSx + Secrets Manager + APCu-cached
reads from settings.php. Full details in
[docs/FSX-LAYOUT.md "Secret propagation"](../FSX-LAYOUT.md#secret-propagation--how-a-config-change-reaches-running-workers).

Summary of the flows:

| Operation | Mechanism | Restart required? |
|---|---|---|
| Add site | Write new `site-meta.yml` + new vhost; `make reload-nginx` | NGINX reload (graceful); **no PHP-FPM restart** |
| Remove site | Delete vhost + (optionally) move site data to archive; `make reload-nginx` | NGINX reload; no PHP-FPM restart |
| Rotate site DB password | ALTER USER + update Secrets Manager + bump `site-meta.yml` cache-stamp | Neither |
| Change site PHP version | Update vhost upstream + update `site-meta.yml`; `make reload-nginx` | NGINX reload; PHP-FPM unaffected because workers don't care about site version |
| Update Drupal code (composer) | Write to FSx + `make restart-php-fpm` | **Yes — PHP-FPM restart** (OPcache holds compiled PHP) |
| Update settings.php logic itself | Same as above | **Yes — PHP-FPM restart** |

So restart-php-fpm is reserved for **code** changes (PHP files
themselves) and **never** for config or secret changes.

## Backup architecture: three Drupal data zones

Drupal data lives in three distinct zones with different change rates
and different backup strategies. Multi-tenancy makes the per-site
granularity especially important.

For the full details, see
[docs/FSX-LAYOUT.md "Backup model"](../FSX-LAYOUT.md#backup-model).
Summary:

| Zone | Where | Backup | Frequency | Granularity |
|---|---|---|---|---|
| **Database** | RDS per env, one DB per site | Automated snapshots + PITR | Continuous | Per-DB (per site) |
| **Codebase** | FSx `/fsx/sites/<slug>/drupal/` | FSx OpenZFS snapshots | Daily, 14-day retention | Per env (snapshot-level); per-file via FSx file-restore |
| **Customer assets** | FSx `/fsx/sites/<slug>/drupal/web/sites/default/files/` and `drupal-private/files/` | FSx snapshots **+** per-site git deltas to self-hosted GitLab CE | Daily (cron) | Per-site, per-day |

The customer-asset git capture is the new addition specific to this
revision. Pattern:
- Per-site `.git/` storage on a separate EBS volume attached to the
  deploy-host (not on FSx — don't back up the backup).
- `GIT_DIR` / `GIT_WORK_TREE` env vars on deploy-host's nightly cron
  point at the working tree on FSx and the storage on EBS, respectively.
- Push destination: self-hosted GitLab CE EC2 (see Git Hosting Strategy
  below — same host serves both the code repos and the asset-backup
  repos).

## Git Hosting Strategy

The Drupal site repos (where `composer.lock`, custom modules, custom
themes, and config live) need a host. Same host can also serve as the
asset-backup remote (above).

### Current state of options

| Host | Status | Notes |
|------|--------|-------|
| **AWS CodeCommit** | **In maintenance mode (since July 2024)** | No new customer onboarding. Existing customers (worxco) can keep using and creating new repos. Future migration risk. Per-AWS-account — works in worxco's account, but Zoning Inc may not have it enabled. |
| **GitHub** | Healthy | Where `cf-scalable-web` lives today. Cross-AWS-account-friendly. May not satisfy "local to my AWS account" customers. |
| **Bitbucket** | Healthy | Atlassian. Some customers prefer it (corporate Atlassian shops). |
| **GitLab.com** | Healthy | Hosted GitLab. Free tier limits private repos. |
| **GitLab CE (self-hosted)** | Healthy, **fully open source (MIT)** | Run your own on EC2 + EBS. ~$15-20/mo for small instance. Total control. **Recommended** for worxco internally — also serves as the customer-asset backup remote. |

### Strategic direction

Different customers have different constraints:

- **Some customers** require all source code to live inside their own
  AWS account (compliance, data residency, billing centralization).
  For these, options are:
  - CodeCommit (deprecated — limited future)
  - Self-hosted GitLab CE on a small EC2 in their account
  - S3-backed git remotes (`git-remote-s3`) — primitive but AWS-native
- **Other customers** are happy with GitHub/Bitbucket/external GitLab.
  Simpler ops; works fine for most.
- **Worxco internally** (Model A): self-hosted GitLab CE for
  centralized billing, security, vendor-independence, AND as the
  customer-asset backup remote (one EC2 serving both purposes).

### Implication for the tooling

The Drupal lifecycle scripts (`install-drupal.sh`, future
`upgrade-drupal.sh`, future `promote-drupal.sh`) should accept a
**git URL** as a parameter and not care which host serves it. Treat
the git host as configuration, not architecture.

This means the install/upgrade tooling becomes git-agnostic: same
script works with `git@codecommit:...`, `git@github.com:...`,
`git@gitlab.worxco.internal:...`, etc. The deploy-host already
supports this via SSH config — multiple `Host` blocks for different
remotes, each with its own deploy key.

## Layered Codebase: Base + Per-Site Overlay

**Decided: one codebase per site** (Kurt's call 2026-05-20 — has
operated the shared-codebase model in production and found the
coupling issues unacceptable). Sites do not share code at runtime.
Update lifecycles are per-site.

The shared-vs-per-site question is decided. What follows is the repo
structure for the per-site model, with a shared *base* that sites
depend on at composer-resolution time (not at runtime).

### Repository structure

```
worxco-drupal-base/                      ← shared base (one repo, many sites depend on it)
  composer.json                          ← Drupal core + standard modules
                                           every site uses (admin_toolbar,
                                           pathauto, redis, ckeditor5, etc.)
  config/sync/                           ← shared base config (defaults)
  web/modules/custom/worxco_*/           ← shared custom modules (e.g.,
                                           worxco_branding, worxco_seo_helpers)
  web/themes/custom/worxco_base/         ← shared base theme (subtheme-able)

worxco-drupal-site-client1/              ← per-site overlay (one repo per site)
  composer.json                          ← requires worxco-drupal-base@^1.0
                                           + client1-specific modules/themes
  config/sync/                           ← client1 config (overrides + additions)
  web/modules/custom/client1_*/          ← client1's custom modules
  web/themes/custom/client1_theme/       ← client1's theme (subtheme of worxco_base)
  README.md                              ← client1-specific notes, contacts

worxco-drupal-site-client2/              ← another per-site overlay
  ...

worxco-drupal-site-default/              ← template for new sites (start here)
  ...
```

### How it composes at install time

A site's install pulls only its own per-site repo. `composer install`
resolves the dependency on `worxco-drupal-base@^1.0` and pulls the base
in via composer (through composer's git-based VCS support, since the
base lives in a private git repo). Result: each site has a complete,
self-contained codebase derived from base + overlay — **its own
`vendor/`, its own `drupal/`, fully independent at runtime**.

### Benefits

- **Per-site freedom**: each site can pin its own module versions, add
  custom modules/themes, override base config — independently
- **Separate deploy/promote lifecycle**: client1's upgrade window
  doesn't block client2's upgrade window
- **Clean audit trail per client**: site repo's git history is the
  client's change history (what was deployed when, by whom)
- **Easier offboarding**: if a customer leaves, their site repo is
  theirs to take. The base stays.
- **Patched base auto-flows on next install**: `worxco-drupal-base@^1.0`
  picks up patch versions automatically on the next `composer install`
  per site (so a security fix in the base reaches all sites without
  per-site code changes — but per-site PHP-FPM restart is still
  needed to clear OPcache).

### Trade-offs

- **More repos to manage**: one base + one per site. For 50 client
  sites, that's 51 repos. Works fine with proper tooling, but it's
  not nothing.
- **Base evolution discipline**: changes to base affect every site on
  its next composer install. Need a versioning + release-notes
  discipline for the base repo. Semver helps: patch auto-applied;
  minor/major opt-in per site.
- **Disk usage**: ~50 MB per site for vendor/ alone, multiplied by N
  sites. FSx volume sizing should account for this.

## Design Questions (deferred to team discussion)

Tabled for later — these need input from team members and probably a
few spike implementations to settle.

### Q1: Base evolution policy

- **Auto-apply on patch and minor**: every `composer install` picks up
  `^1.0` matching versions. Most production-friendly for security
  patches, but a base bug can affect all sites simultaneously.
- **Opt-in per site**: each site explicitly bumps its base version
  when ready. Safer per site, but security patches require active
  rollout.
- **Hybrid**: auto-apply patch versions only; minor and major are
  opt-in. Probably the right answer for production.

### Q2: Per-site dev environments

- Does a developer working on client1's custom module get their own
  AWS-hosted dev environment, or do they share the sandbox?
- For Model A (worxco hosting), spinning up a dev env per developer
  is expensive. Probably need a "developer laptop with DDEV/Docker
  mirroring production" approach instead.
- For Model B (corporate IT), the customer's IT team makes this call.

### Q3: Cross-site database isolation

- All site DBs in one RDS instance per environment, or separate RDS
  per big tenant?
- Cost: one shared RDS is cheaper. Isolation: separate RDS is stronger.
- Probably depends on customer tier (small clients share, enterprise
  clients get their own).
- Note: per-site DB *user* + per-site DB *name* in the same RDS already
  gives decent logical isolation; physical isolation requires a
  separate RDS.

### Q4: Tenant offboarding workflow

- When a client leaves, how do we cleanly tear down their site without
  affecting others?
- Probably a `make destroy-site SITE=client1 ENV=production` target
  that: drops DB, removes FSx files, deletes secrets, deletes their
  app stack, deletes their NGINX server block. Needs careful design
  and lots of confirmation prompts.
- Asset history (the per-site git repo on GitLab CE) is preserved by
  default — destroying the site doesn't destroy the audit trail.

## What Current Phase C Should Keep Compatible

While Phase C is single-site, the choices we make today should not
block the multi-tenant refactor later. Specific constraints (updated
for the env-out-of-paths direction):

- **Path conventions**: today single-site uses `/var/www/drupal/`. The
  future is `/var/www/sites/<site-slug>/drupal/`. Single-site can
  remain at `/var/www/drupal/` for now; the migration to
  `/var/www/sites/default/drupal/` is mechanical and deferred to the
  multi-tenant refactor. **Do NOT reintroduce `<env>` to the path** —
  that was a rejected direction.
- **Config naming**: secrets and SSM parameters today use
  `<env>/drupal/*`. Future is `<env>/sites/<site-slug>/*`. **Don't bake
  "drupal" as a magic literal** in shared library code; treat it as
  the site identifier of a default-named single site. Per-site code
  paths are easier to add later if the variable name is
  `SITE_SLUG=drupal` than if it's hardcoded `"drupal"`.
- **DB user naming**: `drupal_user` is fine for now. Future is
  `drupal_<site-slug>_user`. Same pattern: parameterize even when
  default.
- **NGINX server block**: today's NGINX has one server block (just
  added 2026-05-19) that points at `/var/www/drupal/web`. The future
  is multiple server blocks per `server_name` plus an explicit
  `default_server` returning 404 for unknown Host headers. The current
  single block does not need a `default_server` directive yet —
  defer until the second site is added.
- **Config delivery to PHP**: today uses `env[]` in `www.conf` at boot
  (single-site, one set of env vars for the whole pool). **Do not
  build per-site logic on top of this** — it doesn't scale.
  Multi-tenant will use the `site-meta.yml` + Secrets Manager pattern
  documented in `docs/FSX-LAYOUT.md`. Single-site work can use the
  env[] approach as a placeholder; the transition will be in the
  multi-tenant refactor.
- **Make target naming**: `install-drupal` is fine for now. Future is
  `install-site` with a SITE parameter. Don't paint into a corner
  with target names that imply "there can only be one."

In short: build for one, name for many, **keep env out of FSx paths**.

## Out of Scope (deliberately)

The following are NOT part of this plan and should not influence current
Phase C work:

- **Choosing the site repo git host**: we'll pick at the start of the
  actual multi-tenant work, based on the customer scenario at the
  time. Self-hosted GitLab CE is the leading candidate for worxco
  internally.
- **Building the site repo template**: deferred until we're ready to
  take Phase C through `composer install`-from-git
- **Refactoring NGINX config for multi-tenancy**: deferred to Phase E
- **Per-site PHP version routing**: foundation already in NLB;
  application layer wiring is Phase F
- **Site offboarding tooling**: Phase H, far future

## Suggested Future Phasing

| Phase | Scope | Notes |
|-------|-------|-------|
| **C** | Single-site cloud install (RDS + FSx + env-var settings.php) | **Current** — in progress |
| **D** | Single-site upgrade and promote infrastructure (composer.lock-driven, drush updb workflow, backup-before-upgrade, maintenance-mode wrapper) | Per `Drupal upgrade and promote infrastructure` TODO |
| **E** | Multi-site refactor: introduce SITE parameter, per-site path/DB/secret layout, NGINX `server_name` routing, transition config delivery to `site-meta.yml` model | After D |
| **F** | Per-site PHP version routing wired to NLB ports | Foundation exists; this is the application-layer wiring |
| **G** | Layered codebase: base + per-site overlay, composer-based dependency between repos; per-site git remotes | The full multi-tenant codebase model |
| **H** | Site offboarding, archival, restore tooling | The "delete a tenant cleanly" workflow |

Each phase has natural validation in the previous one. C validates the
install on real infrastructure; D validates upgrade workflows on a
single site; E adds the second site (and inevitably surfaces issues
that "single site assumed" choices made earlier); etc.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
