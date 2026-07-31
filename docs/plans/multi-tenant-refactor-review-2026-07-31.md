---
name: Multi-Tenant Refactor — Review & Decision Package
description: Comprehensive planning document for evolving cf-scalable-web from single-site to multi-tenant hosting platform. For solo review + markup before implementation begins.
audience: kurt-solo-review
status: DRAFT — awaiting review
date: 2026-07-31
supersedes:
  - docs/plans/multi-tenancy.md (path-layout, DB-user, config-delivery sections — see §6)
  - docs/FSX-LAYOUT.md (path-layout, secret-propagation sections — see §6)
does-not-supersede:
  - docs/plans/multi-tenancy.md (deployment models A/B, three-role access, git-hosting strategy, backup zones, layered-codebase discussion, phased roadmap C→H, deferred design questions — all still current)
  - docs/FSX-LAYOUT.md (two-mount invariant, `<env>`-never-in-paths invariant, deploy-host-is-only-writer invariant — all still current)
---

# Multi-Tenant Refactor — Review & Decision Package

## §1 — Executive Summary

**What this is.** A single-file review artifact capturing every
decision, conflict, and unresolved question about the multi-tenant
refactor as of 2026-07-31. Intended for print + solo markup before
implementation begins.

**What multi-tenant means (in this project).** N independent PHP app
installations coexisting on shared infrastructure. Each site is its
own full app tree — its own `vendor/`, its own `composer.json`, its
own Drupal version (or WordPress version, or Laravel version). Only
the physical infrastructure (nginx fleet, PHP-FPM fleets, RDS cluster,
FSx OpenZFS, ElastiCache Valkey, ALB) is shared. This is NOT Drupal's
built-in "multi-site" feature (which forces all sites to share one
Drupal codebase).

**MVP scope.** Two coexisting sites in sandbox, each independently
installable, backupable, restorable. Cross-site contamination provably
impossible.

**Deferred (design does not preclude).** Clone, archive, rename,
apply-updates-with-rollback, WordPress support, web UI, no-restart
secret rotation via the more sophisticated `site-meta.yml` + Secrets
Manager + APCu design already documented in `docs/FSX-LAYOUT.md`.

**Key infrastructure facts** (from tonight's codebase audit):
- nginx.conf already uses `include /etc/nginx/shared/sites-enabled/*.conf`
  — the multi-vhost plumbing is READY today; only the vhost writers
  and their inputs need to change.
- PHP-FPM already fronts two versions (7.4 and 8.3) with per-vhost
  `fastcgi_pass php74|php83` — the per-site PHP-version selector is
  already the mechanism, just currently hardcoded to `php83`.
- The `drupal.conf` vhost is written by TWO scripts today
  (`install-drupal.sh` heredoc AND `publish-drupal-vhost.sh`) — must
  consolidate.
- Prior planning docs already picked cleaner endpoints (per-site DB
  user, YAML+SecretsManager+APCu). Tonight's MVP consciously trades
  some polish for smaller scope. Prior endpoints are still the target
  for later phases.

**Recommended next steps** (post-review):
1. Kurt marks up this doc, resolves open questions in §12.
2. Merge accepted decisions into `docs/plans/multi-tenancy.md` and
   `docs/FSX-LAYOUT.md` (single source of truth).
3. Schedule the implementation phases (§10) into the work backlog.

---

## §2 — What Kurt Actually Wants (framing clarification from
2026-07-31 conversation)

Two very different things are called "multi-site":

**Drupal's own multi-site feature (NOT what we're building).** One
Drupal codebase installed once. `web/sites/<name>/settings.php` per
site. `sites.php` maps Host headers to directories. All sites forced
to the same Drupal core, contrib modules, patches, PHP requirements.
Coupled release lifecycle: a Drupal 10→11 upgrade moves every site
simultaneously. This is what the term "Drupal multi-site" means in
the Drupal community.

**Multi-tenant infrastructure (what we ARE building).** Each site is
a complete, independent PHP app installation at `/var/www/<site>/`.
Each has its own `vendor/`, its own `composer.json`, its own
`web/index.php`. Could be Drupal 11 for one site, Drupal 10 for
another, WordPress 6.x for a third. All coexist on shared
infrastructure (nginx, PHP-FPM, RDS, FSx, Valkey, ALB). Decoupled
release lifecycles. Independent security posture per site.

The infrastructure code is Drupal-focused today (install-drupal.sh,
etc.). Adding WordPress support means adding a `install-wp.sh` and
a per-site `APP_TYPE=drupal|wordpress` dispatch — no infrastructure
change. This is a Phase-5+ concern; not in MVP.

---

## §3 — Current State of the Codebase (audit 2026-07-31)

**Two Explore agents mapped the current architecture in
comprehensive detail. Summarized here; see Appendix A + B for the
file:line specifics.**

### 3.1 Filesystem (single-tenant hardcodes)
- `/var/www/drupal/` — Drupal install root
- `/var/www/drupal-private/` — private files
- `/var/www/drupal-config/` — config sync
- All three hardcoded in `install-drupal.sh:71-73` and consumed by
  ~15 scripts + Makefile targets.

### 3.2 Database
- Postgres cluster shared per env; single DB name `drupal`; schema
  `zinew` (from prod migration source, set in settings.php via env var
  `DRUPAL_DB_SCHEMA` — added 2026-07-31 to fix the `public.search_dataset`
  bug documented in prior commit `704506b`).
- DB user `drupal_user` (single, shared per cluster).

### 3.3 nginx + PHP-FPM request flow
`ALB → nginx (port 80) → NLB → PHP-FPM (port 9000)`.

- `image-builder/configs/nginx/nginx.conf:108` already has
  `include /etc/nginx/shared/sites-enabled/*.conf` — **multi-vhost
  ready**. `/etc/nginx/shared` is an NFS mount of FSx subtree
  `/fsx/nginx`.
- Vhost file today: single `drupal.conf`, written by BOTH
  `scripts/publish-drupal-vhost.sh:79` and (redundantly)
  `scripts/deploy-host/install-drupal.sh:660`. Both writers must
  consolidate into one.
- PHP version selection: `configure-nginx.sh` writes an
  `/etc/nginx/conf.d/upstream-php.conf` at boot naming two upstreams
  (`upstream php74` and `upstream php83`) pointing at the NLB on
  ports 9074 and 9083. The vhost picks via `fastcgi_pass php74|php83`
  (currently hardcoded to `php83`).
- Two independent PHP ASGs (`${env}-php74-asg`, `${env}-php83-asg`)
  behind NLB target groups on 9074/9083 → forward to PHP-FPM 9000.

### 3.4 PHP-FPM env delivery (the KEY multi-tenant challenge)
- Single `[www]` pool per instance (`image-builder/configs/php/8.3/www.conf`).
- At boot, `configure-php.sh:135-180` reads SSM + Secrets Manager and
  writes `env[DRUPAL_DB_HOST]`, `env[DRUPAL_DB_NAME]`,
  `env[DRUPAL_HASH_SALT]`, `env[AWS_S3_BUCKET]`, `env[DRUPAL_SITE_NAME]`,
  etc. into the pool config.
- Env vars are **process-level state**. All FPM workers inherit them.
  Every request sees the same values.
- **This does not generalize to multi-tenant**: cannot have Site A's
  `DRUPAL_DB_NAME=zoning_info_platform` and Site B's
  `DRUPAL_DB_NAME=demo` in the same pool. See §8 for how tonight's
  decision resolves this.

### 3.5 Migration
- S3 dump keys: `dumps/drupal-codebase.tar.gz`,
  `dumps/drupal-files.tar.gz`, `dumps/drupal-private.tar.gz`,
  `dumps/zinew.sql`. All site-scoped, need namespacing under
  `dumps/<site>/`.
- Restore scripts pinned to `/var/www/drupal/*`.
- `migration/Makefile:820-903` pins `ENV=sandbox` throughout.
- Prod jumpbox `dump-codebase.sh:74`, `dump-files.sh:62`,
  `dump-private.sh:60` hardcode `DRUPAL_ROOT="/var/www/html/zoning_info_platform"`.

### 3.6 CFN + Secrets + SSM (per-site content mis-scoped as per-env)
- `cloudformation/cf-app-drupal.yaml` — ONE stack per env containing
  ALL per-site content: `DrupalAdminPasswordSecret`,
  `DrupalDBPasswordSecret`, SSM params `/env/drupal/{site-name,
  db-name, db-user, install-path, admin-username, admin-email}`.
  Every one of these resources becomes N resources under multi-tenant.
- SSM hierarchy today: `/<env>/drupal/*` → becomes `/<env>/sites/<X>/*`.
- Secrets Manager: `worxco/<env>/drupal/*` → becomes
  `worxco/<env>/sites/<X>/*`.
- `cloudformation/cf-iam.yaml:179` grants PHP compute role
  `${SecretNamePrefix}/drupal/*` → widens to `${SecretNamePrefix}/sites/*/*`.

### 3.7 Existing multi-site scaffolding
**Zero.** Every reference targets `sites/default`. No `sites.php`.
Vhost filename fixed `drupal.conf`. ASG names per-env not per-site.
SSM param `/<env>/drupal/site-name` returns a scalar.

**Only positive scaffolding**: nginx's `include *.conf` glob and the
two-PHP-version NLB fan-out. Neither requires any change to support
N sites.

---

## §4 — Prior Planning (what's already documented — still valid)

Two docs pre-date tonight and remain the structural framework:

### 4.1 `docs/plans/multi-tenancy.md` (2026-05-08, revised 2026-05-20; 447 lines)

**Sections that remain fully valid** (not superseded by tonight):

- **Two deployment models** (§ "Two Deployment Models"):
  - Model A: **Managed hosting (Worxco)** — Worxco owns AWS account,
    hosts many clients' sites on it.
  - Model B: **Self-managed (corporate IT)** — customer owns their
    AWS account, hosts their own portfolio.
  - Same infrastructure code serves both; differences are purely
    operational (who owns what, who runs what).

- **Three-role access model** (§ "Three Roles, Three Channels"):
  - End User — Drupal admin UI only, one site
  - IT Operator — deploy-host, drush, composer, all sites' admin UI
  - Platform Team — full AWS account, IAM, CFN, all secrets
  - Enforced by architecture: end users have only HTTP access via
    the ALB; no SSM, no SSH, no FSx path.

- **Environment isolation via AWS resources** (§ "Environment
  isolation..."): each env has its own FSx, RDS, Valkey. `<env>`
  NEVER appears in FSx paths. This is a hard invariant.

- **Git hosting strategy** (§ "Git Hosting Strategy"): CodeCommit
  deprecated; self-hosted GitLab CE recommended for Worxco internally;
  customer preferences vary. Drupal lifecycle scripts should be
  git-agnostic (accept URL as parameter).

- **Layered codebase discussion** (§ "Layered Codebase..."): "one
  codebase per site" decided (Kurt 2026-05-20). Base repo
  (`worxco-drupal-base`) + per-site overlay repos via composer
  dependency. Not MVP; Phase G in prior roadmap.

- **Deferred design questions** (§ "Design Questions"): base evolution
  policy, per-site dev environments, cross-site DB isolation, tenant
  offboarding workflow. Still open.

- **Phased roadmap C→H** (§ "Suggested Future Phasing"):
  - C: Single-site cloud install ← **CURRENT (complete as of tonight)**
  - D: Upgrade + promote infrastructure
  - E: Multi-site refactor ← **what tonight is planning (Phases 1-4 here)**
  - F: Per-site PHP version routing
  - G: Layered codebase
  - H: Site offboarding
  - Tonight's Phase 1-4 aligns to prior E; Phase 5+ deferred items
    align to F/G/H.

**Sections that are SUPERSEDED by tonight** (see §6 for details):
- "What Multi-Tenancy Changes" table — path layout, DB naming, config
  delivery rows are superseded.
- "Per-site config delivery and propagation" — the `site-meta.yml` +
  APCu design is now Phase 5+ target, not MVP mechanism.
- "What Current Phase C Should Keep Compatible" — path constraint
  slightly changes given tonight's flatter layout.

### 4.2 `docs/FSX-LAYOUT.md` (2026-05-20; 362 lines)

**Sections that remain fully valid:**

- **Volume model**: one FSx per env. Root is `/fsx`. Two sibling
  subtrees: `/fsx/www` and `/fsx/nginx`.

- **Two mount points** (§ "Mount points"): sibling layout for
  defense-in-depth (PHP-FPM can only reach `/fsx/www`, not
  `/fsx/nginx`). "No more than two logical FSx mount points"
  invariant #5.

- **File ownership model** (§ "File ownership and permissions"):
  deploy-host is the only writer; PHP-FPM workers write only to
  per-site `files/` dirs; secrets never live in FSx files.

- **Anti-drift invariants** (§ "Single-source-of-truth invariants"):
  no `<env>` in FSx paths, secrets never in FSx files,
  deploy-host-is-only-writer, one FSx per env, no third mount point.

- **Backup zones**: three-zone model (database / codebase / customer
  assets) with per-site granularity. Full details in that doc.

**Sections that are SUPERSEDED by tonight** (see §6):
- "Top-level directory structure" — path layout
  `/fsx/www/sites/<slug>/drupal/` + `drupal-private/` + `drupal-config/`
  is superseded by tonight's single-tree layout.
- "Per-site config: `site-meta.yml`" — YAML + Secrets Manager
  fetch + APCu cache design is deferred to Phase 5+; MVP uses `.env`
  in the site tree.
- "Secret propagation" flow diagrams — apply to the Phase-5+ design,
  not the MVP.

### 4.3 `docs/memory/drush-aliases-multi-tenancy.md` (2026-05-20)
Design notes for Drush aliases across many sites. Tonight didn't
discuss drush aliases. Prior memory's recommendation (Option A:
symlinks into `/etc/drush/sites/`) stands as the current thinking
for a future phase.

---

## §5 — Tonight's Decisions (locked 2026-07-31)

Each decision below was explicitly confirmed with Kurt via
AskUserQuestion or direct conversation.

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 5.1 | Multi-tenant framing | Each site = independent app tree; not Drupal-multi-site | See §2 |
| 5.2 | Directory layout | Single tree per site: `/var/www/<site>/{web, vendor, composer.json, private, config}` | See §6.1 + §12 Rationale |
| 5.3 | Existing site rename | `drupal` → `zoning_info_platform` in Phase 1 | Matches jumpbox source dir; underscores clean for Postgres DB names |
| 5.4 | Per-site config mechanism | `/var/www/<site>/.env` shell file, read by `settings.php` via `__DIR__` self-locating | See §8; matches WordPress/Laravel/Drupal conventions; zero new mount points |
| 5.5 | PHP-FPM pool | Single `[www]` pool per instance (unchanged); env[] narrowed to infra-only | See §8; pool-per-site would multiply NLB target groups + ASGs by N |
| 5.6 | DB naming | DB name = site name (underscored) | Matches Kurt's mental model ("db server managing multiple databases"); simpler archive/clone semantics |
| 5.7 | DB user | Shared `drupal_user` for MVP | Per-site users add Secrets/IAM churn; no MVP requirement forces this now |
| 5.8 | SITE= parameter | Required on every site-scoped Makefile target | Kurt's explicit "must not migrate to wrong site"; bare `make install-site` fails with helpful message |
| 5.9 | App-family abstraction | None for MVP (Drupal-specific install script) | YAGNI; WordPress dispatcher is straightforward when needed |

---

## §6 — Conflicts Between Prior Planning and Tonight (with Resolutions)

Tonight's decisions supersede prior in three specific areas. Others
are unchanged. Kurt chose "Tonight's decisions supersede prior
planning (Recommended)" for the reconciliation approach.

| Aspect | Prior planning (2026-05-20) | Tonight (2026-07-31) | Winner | Deferred (revisit later)? |
|---|---|---|---|---|
| Path layout | `/var/www/sites/<slug>/drupal/{web,vendor}` + `/var/www/sites/<slug>/drupal-private/` + `/var/www/sites/<slug>/drupal-config/` (nested `sites/` prefix + three sibling dirs per site) | `/var/www/<site>/{web, vendor, composer.json, private, config}` (flat, single tree per site) | **Tonight** | Prior can be adopted later if needed for future consistency, but no operational requirement forces it. |
| Config mechanism | `site-meta.yml` (YAML) on FSx + secret *references* only + `settings.php` fetches from Secrets Manager at request time + APCu 60s cache + nginx passes `SITE_SLUG` as fastcgi_param | `/var/www/<site>/.env` shell file on FSx + `settings.php` reads via `__DIR__` self-locating + values written directly by deploy-host from Secrets Manager | **Tonight (MVP)** | **Prior design is the Phase 5+ target.** It enables no-restart secret rotation and keeps secrets out of FSx files entirely — architecturally cleaner. MVP trades this for smaller scope. |
| DB user per site | `drupal_<site>_user` per site (per-site Secrets Manager entries) | Shared `drupal_user` for MVP | **Tonight (MVP)** | Prior is a straightforward later upgrade; no MVP need. |

**Not conflicts, but worth noting:**
- Tonight introduces `SITE=` as required on Make targets — prior docs
  suggested this direction ("build for one, name for many") but
  didn't specify enforcement.
- Tonight's "single-tree" layout means `private/` is a SIBLING of
  `web/` inside the site tree — different filesystem structure but
  same security invariant as prior (private outside webroot); see §9.

**Rationale for tonight's simpler MVP direction:**
- Prior design's `site-meta.yml` + AWS SDK + APCu is elegant but
  requires PHP AWS SDK in every settings.php request path, APCu
  configuration, YAML parser, and per-request Secrets Manager calls
  (with careful cache invalidation). Real code.
- Tonight's `.env` + write-once-on-config-change is 20 lines in
  settings.php + a shell script to regenerate the file. Ships faster.
- Both mechanisms fit the "co-located per-site config on FSx"
  spirit; the Phase-5+ upgrade path is well-understood.

---

## §7 — Namespace Convention (Before → After)

| Concern | Before (single-tenant) | After (site X in env E) |
|---|---|---|
| Web root | `/var/www/drupal/web` | `/var/www/<X>/web` |
| Private files | `/var/www/drupal-private` | `/var/www/<X>/private` |
| Config sync | `/var/www/drupal-config` | `/var/www/<X>/config` |
| Install marker | `/var/www/drupal/.installed` | `/var/www/<X>/.installed` |
| Per-env shell env (infra) | `/etc/worxco/envs/<E>` | Kept as-is for MVP (deploy-host-local; standalone rename to `/etc/webplatform/envs/<E>` is an orthogonal PR later). See §12 Q4. |
| **Per-site config (NEW)** | (none) | `/var/www/<X>/.env` — DB creds, salt, S3 bucket, PHP version, DB schema. Owner `root`, group `www-data`, mode `0640`. |
| nginx vhost | `/fsx/nginx/sites-enabled/drupal.conf` | `/fsx/nginx/sites-enabled/<X>.conf` |
| DB name | `drupal` | `<X>` (underscored: `-` → `_`) |
| DB schema | `zinew` (from migration source) | Per-site value in `<X>.env`; default `public` for fresh installs |
| SSM params | `/<E>/drupal/*` | `/<E>/sites/<X>/*` |
| Secrets Manager | `worxco/<E>/drupal/*` | `worxco/<E>/sites/<X>/*` |
| IAM wildcard | `${SecretNamePrefix}/drupal/*` | `${SecretNamePrefix}/sites/*/*` |
| Migration dump keys | `dumps/drupal-{codebase,files,private}.tar.gz`, `dumps/zinew.sql` | `dumps/<X>/{codebase,files,private}.tar.gz`, `dumps/<X>/db.sql` |
| CFN app stack | `cf-scalable-web-<E>-app-drupal` | `cf-scalable-web-<E>-app-site-<X>` (one per site) |

---

## §8 — How Env Vars Work in Multi-Tenant (mechanism deep-dive)

**The problem.** PHP-FPM env vars are process-level state. The FPM
master reads them at boot; all workers inherit them. That works
single-tenant because there's one set of DB credentials. It breaks
multi-tenant because two sites can't share one pool AND see different
DB creds — the pool has one value each.

**The solution: split env into two tiers.**

### 8.1 Infra tier (unchanged)
- Values that are truly cross-site: RDS cluster endpoint, Valkey
  endpoint + auth token, `ENVIRONMENT_NAME`.
- Injected into FPM `[www]` pool at boot by `configure-php.sh` reading
  SSM + Secrets Manager. Same values across all requests, all sites.

### 8.2 Site tier (NEW)
- Values that are per-site: DB name + user + password, hash salt,
  S3 bucket name, chosen PHP version, DB schema.
- **NOT env vars.** Live in `/var/www/<site>/.env` on FSx.
- Each site's `settings.php` reads its OWN `.env` file via
  `require dirname(__DIR__, 3) . '/.env'` — self-locating from the
  path the file lives at.
- Because Drupal for a given request loads
  `/var/www/zoning_info_platform/web/sites/default/settings.php`
  (based on nginx's `root` for that vhost), THAT settings.php reads
  THAT `.env`, and cross-site contamination is physically impossible.

### 8.3 Source of truth
- SSM + Secrets Manager remain authoritative.
- `.env` on FSx is a generated mirror written by the deploy-host.
- `refresh-site-env SITE=X` regenerates it (idempotent).
- Rotating a DB password: update Secrets Manager → run
  `refresh-site-env` on deploy-host → new `.env` visible to all
  PHP-FPM boxes on next request (FSx is shared; no per-box sync).

### 8.4 Why FSx and not `/etc/`
Three reasons:
1. **Co-location.** WordPress puts `wp-config.php` IN the app tree.
   Laravel puts `.env` IN the app tree. Drupal itself puts
   `settings.php` IN the app tree. Nothing about the site's config
   should live outside the site.
2. **Zero new mount points.** FSx `/var/www/` is already there and
   already shared. Adding `/etc/webplatform/` would need a third
   mount, which the FSX-LAYOUT invariant #5 explicitly forbids.
3. **Backup/clone/archive are naturally correct.** Moving a site
   directory takes its config with it — no orphaned `/etc/` file to
   remember.

### 8.5 What DOESN'T change
- PHP-FPM still uses env vars for infra (ENVIRONMENT_NAME, Valkey)
- `configure-php.sh` still runs at boot to inject those
- `/etc/worxco/envs/<E>` on deploy-host still exists (infra-only for MVP)
- What's ADDED: per-site `.env` files, populated by a new
  `refresh-site-env.sh SITE=X` action

---

## §9 — Private Files Security Invariant

**The security question**: with `private/` inside the site tree, does
nginx have any path to serve those files?

**No.** In the single-tree layout, `private/` is a sibling of `web/`:

```
/var/www/<site>/
├── web/          ← nginx root points HERE
├── vendor/       ← above nginx root — unreachable
├── private/      ← above nginx root — UNREACHABLE by nginx
└── config/       ← above nginx root — unreachable
```

**Nginx has a compiled-in filesystem constraint: it cannot serve
files above its `root` directive.** This is not a `location` block
that could be regressed by a template edit. It is an nginx behavior
that would require rebuilding nginx from source to disable.

`private/` therefore is physically unreachable via any URL,
regardless of what the vhost config says. This satisfies the Drupal
community "private files outside webroot" best practice — which is
about protecting private files from direct-URL access. Community docs
sometimes place `private/` one level higher (as a sibling of the
entire site tree, e.g. `/var/www/<site>/` + `/var/www/<site>-private/`)
but that offers no additional protection over ours: what matters is
that private is above nginx `root`, and ours is.

**Belt-and-suspenders**: the vhost still includes an explicit
`location /private/ { deny all; return 404; }` as documentation +
defense-in-depth. That rule should never actually fire.

**Verification test in Phase 3**: `curl -H 'Host: <site>' https://.../.env`
must return 404, not the file contents.

---

## §10 — Phased Implementation Proposal

Aligns with Phase E in the prior roadmap (`docs/plans/multi-tenancy.md`
§ "Suggested Future Phasing").

### Phase 1 — Namespace pivot (existing site, functionally unchanged)
Parameterize `scripts/deploy-host/install-drupal.sh` on `SITE`.
Change INSTALL_DIR/PRIVATE_DIR/CONFIG_DIR to
`/var/www/$SITE/{web, private, config}`. Rewrite the settings.php
heredoc to self-locate via `__DIR__` and require
`dirname(__DIR__, 3) . '/.env'` — reads the per-site config from the
site's own tree; no more `getenv()` for site-scoped data.

Create a one-shot
`scripts/deploy-host/rename-legacy-site.sh drupal zoning_info_platform`
that shuts down PHP-FPM briefly, `mv`s the three current top-level
dirs into the new single-tree layout, writes the new per-site `.env`,
renames the DB, republishes the vhost.

**Deliverable**: existing sandbox site works, now at
`/var/www/zoning_info_platform/`, identified as
`SITE=zoning_info_platform` throughout.

### Phase 2 — Vhost + PHP-FPM decoupling
Consolidate the two `drupal.conf` writers (heredoc at
`scripts/deploy-host/install-drupal.sh:660` and script
`scripts/publish-drupal-vhost.sh:79`) into a single
`scripts/publish-site-vhost.sh SITE=X ENV=E`. Vhost filename becomes
`<X>.conf`.

Strip the per-site env[] block from
`image-builder/configs/configure-php.sh:135-180` — keep only
`ENVIRONMENT_NAME` + Valkey (truly cross-site infra). All per-site
DB/salt/site-name now flow via settings.php reading `/var/www/<X>/.env`.

Because FSx is shared, rotating any secret = write the new `.env` on
the deploy-host once, all PHP-FPM workers see it on next request.
**No FPM reboot needed for site config changes** after this phase.

Extend `migration/scripts/deploy-host/restore-codebase.sh`'s existing
`PRESERVE_FROM_BAK` mechanism to keep `.env` across codebase restores
(alongside `settings.php` which it already preserves).

### Phase 3 — Second site + per-site backup/restore (MVP DELIVERABLE)
Rename `cloudformation/cf-app-drupal.yaml` → `cf-app-site.yaml` with
a new `SiteName` parameter. Widen IAM wildcard in `cf-iam.yaml:179`
to `${SecretNamePrefix}/sites/*/*`.

Add operator targets:
- `make deploy-app-site SITE=X ENV=E` — creates per-site secrets + SSM
- `make install-site SITE=X ENV=E` — thin wrapper over install-drupal.sh
- `make backup-site SITE=X ENV=E` — tars `/var/www/<X>/` to S3 as
  `site-backups/<X>/<UTC>.tar.zst`; also invokes existing `db-backup`
  with `DB=<X>`
- `make restore-site SITE=X ENV=E BACKUP=<name>` — inverse
- `make list-site-backups SITE=X`

Existing `db-backup.sh` / `db-restore.sh` already accept `DB=`; just
default the DB name from the per-site `.env` file.

Deploy a second site `SITE=demo` to sandbox as validation.

**Deliverable**: two coexisting sandbox sites, each independently
backupable/restorable, cross-site contamination test passes.

### Phase 4 — Migration pipeline site-scoping
Namespace all S3 dump keys under `dumps/<SITE>/`. Make `SITE=`
required on every migration target (`migrate-full-all`,
`migrate-db-all`, all `restore-*` and `dispatch-restore-*`).
Parameterize jumpbox `DRUPAL_ROOT` (currently pinned to
`zoning_info_platform` — becomes the default for that site,
overridable per SITE). Un-pin `ENV=sandbox` in `migration/Makefile`.
Prod dump path becomes site-scoped too.

### Phase 5+ — DEFERRED (design-ready, not built)
- `clone SITE=A NEW=B` — ZFS-snap `/var/www/A` → `/var/www/B` +
  DB dump/restore into new DB + install-site skipping fresh scaffold
- `archive SITE=X` — files-backup + db-backup + `DROP DATABASE X` +
  `mv /var/www/X /var/www/.archive/X-<UTC>`
- `rename SITE=A NEW=B` — DB rename + fs `mv` + regenerate
  vhost/env/SSM
- `apply-updates SITE=X` — pre-snapshot ZFS + backup DB + composer
  update + smoke test + rollback verb
- WordPress support — add `scripts/deploy-host/install-wp.sh` +
  `APP_TYPE=wordpress` dispatch in install-site
- **Adopt prior doc's `site-meta.yml` + Secrets Manager + APCu design**
  for no-restart secret rotation and to keep secrets off FSx entirely
- Per-site `drupal_<site>_user` — one DB user per site
- Per-site PHP version wired end-to-end
- Web UI, self-service provisioning

---

## §11 — Non-Goals for MVP (Explicit Deferrals)

- Clone / archive / rename operator commands (Phase 5+)
- apply-updates-with-rollback (Phase 5+)
- WordPress support (no code; design does not preclude)
- Per-site DB user (shared `drupal_user` retained for MVP)
- Per-site PHP version wired end-to-end (SSM param exists; nginx
  vhost fixed at `fastcgi_pass php83` for MVP)
- The prior doc's `site-meta.yml` + Secrets Manager + APCu
  no-restart-secret-rotation design
- Web UI, self-service provisioning, per-site cron schedules
- Production cutover (MVP proves in sandbox only)
- Renaming `/etc/worxco/envs/<E>` to `/etc/webplatform/envs/<E>` (see
  §12 Q4)

---

## §12 — Open Questions for Kurt to Consider

**Q1: Timing for adopting prior doc's `site-meta.yml` + Secrets
Manager + APCu design.**

That design keeps secrets off FSx entirely and enables no-restart
secret rotation — architecturally cleaner. MVP's `.env` file works
but has secrets on FSx (mode 640, root:www-data, only root+PHP-FPM
can read — but still on disk). Adopt in Phase 5? Or wait until a
concrete need forces it (e.g., a compliance requirement)?

**Q2: Timing for per-site DB user.**

Shared `drupal_user` for MVP means one compromised site could
theoretically access another site's DB (though app-level DB name
filtering prevents accidental cross-writes). Per-site user
`drupal_<site>_user` is a one-time refactor per DB creation. When?
Immediately after MVP proves out? Or when a compliance/audit push
forces it?

**Q3: Git-hosting decision timing.**

Prior doc identifies self-hosted GitLab CE as the leading candidate
but defers the decision. When multi-tenant work starts, this
decision becomes concrete — one repo per site means many repos
appear at once. Worth pre-deciding before Phase 3 delivers site 2.

**Q4: `/etc/webplatform/envs/<E>` renaming timing.**

Discussed tonight: `/etc/worxco/envs/<E>` is client-branded (Kurt
wants this platform reusable by other clients). Tonight's decision
was to defer the rename since the file is deploy-host-local and
sourced only by shell scripts. When to actually do the rename? Small
PR touching ~20 shell files.

**Q5: Sandbox site 2 identity.**

MVP verification requires TWO sites in sandbox. The rename gives us
`SITE=zoning_info_platform` as site 1. Site 2 for testing —
`demo`? `test-site`? `zoning_info_platform_v2` (to test that similar
names don't collide)? Suggest deciding at Phase 3 kickoff.

**Q6: Prior doc's "layered codebase" (base + overlay).**

Prior doc discusses `worxco-drupal-base` + per-site overlay pattern
via composer. MVP treats each site as fully independent (its own
composer.json, no shared base). When (if ever) to introduce the
base? Not MVP; probably not Phase 5 either. Maybe when Worxco has
5+ hosted client sites and the "apply same security patch to all"
overhead becomes real.

---

## §13 — Companion Docs & Cross-References

Existing docs (still authoritative for their scopes):

- **`docs/plans/multi-tenancy.md`** — Two deployment models (§Model
  A/B), three-role access model, git-hosting strategy, layered
  codebase discussion, phased roadmap C→H, deferred design
  questions. Path/config-delivery/DB-user sections superseded by this
  document (see §6 here).
- **`docs/FSX-LAYOUT.md`** — Two-mount FSx model, ownership, backup
  zones, anti-drift invariants. Path-structure and
  secret-propagation sections superseded by this document.
- **`docs/memory/drush-aliases-multi-tenancy.md`** — Drush alias
  strategy for future multi-tenant work. Not touched tonight.
- **`docs/DEPLOY-HOST.md`** (if exists) — deploy-host role
  documentation, control-plane pattern.
- **`docs/plans/drupal-install.md`** — current single-tenant install
  flow. Will need updating in Phase 1.

Recent related commits (tonight):

- `704506b` — settings.php schema=zinew + Phase 9 restart-php-fpm +
  quiet AUTO=yes preflight + cache-data exclusion in dump
- `022532b` — explicit `.DEFAULT_GOAL := help` in migration/Makefile
- `7b396c1` — backtick command-substitution bug in migration/Makefile
  help target

Prior related commits (from prior planning docs):

- `ee319d5` (2026-05-15) — `<env>` removed from FSx paths (cutover
  to per-env-FSx-volume invariant)

---

## Appendix A — Detailed Codebase Audit (from Explore agent, 2026-07-31)

### A.1 Filesystem paths (single-tenant hardcoded, no `SITE=`)
- `INSTALL_DIR="/var/www/drupal"` — `scripts/deploy-host/install-drupal.sh:71`
- `PRIVATE_DIR="/var/www/drupal-private"` — `install-drupal.sh:72`
- `CONFIG_DIR="/var/www/drupal-config"` — `install-drupal.sh:73`
- Consumers: `Makefile:1092,1109,1124,1128`;
  `scripts/admin-login-url.sh:111,119`;
  `scripts/clear-drupal-cache.sh:67`;
  `scripts/install-drupal-remote.sh:101`;
  `scripts/verify-drupal-installed.sh:73,78,83`;
  `scripts/publish-drupal-vhost.sh:63`;
  `scripts/deploy-host/remove-drupal.sh:31-33`;
  `scripts/deploy-host/refresh-env-config:94` (`DRUPAL_PATH=/var/www/drupal`);
  `image-builder/configs/configure-php.sh:56,111`;
  migration `restore-codebase.sh:65,92`, `restore-files.sh:65`,
  `restore-private.sh:36,61`. All site-scoped.

### A.2 Database
- Postgres DB `drupal` — `cf-database.yaml:66`,
  `parameters/*.json:18`, `Makefile:1106,1147,1164,1178`,
  `install-drupal.sh:80`, `scripts/deploy-host/psql-env:45`,
  `refresh-env-config:72`, `clear-drupal-cache.sh:72,76`
- Schema `zinew` — `install-drupal.sh:461,469`,
  `migration/pgloader/zinew.load.tmpl:53`,
  `migration/Makefile:114,618-620`
- User `drupal_user` — `cf-app-drupal.yaml:79`, `install-drupal.sh:81,265`,
  `refresh-env-config:73`, `remove-drupal.sh:70,97,104`

### A.3 CFN
- Stack `${STACK_PREFIX}-app-drupal` where `STACK_PREFIX := cf-scalable-web-$(ENV)`
- Template `cf-app-drupal.yaml`, params `app-drupal-$(ENV).json`
- Cross-stack exports: `${EnvironmentName}-drupal-admin-password-arn`
  (`cf-app-drupal.yaml:270`),
  `${EnvironmentName}-drupal-db-password-arn` (`:280`)
- S3 bucket `${EnvironmentName}-drupal-media-${BucketSuffix}` —
  `cf-storage-s3.yaml:96,119`
- IAM wildcard `${SecretNamePrefix}/drupal/*` — `cf-iam.yaml:179`

### A.4 Makefile targets (top-level Makefile)
Site-scoped: `install-drupal`, `install-drupal-full`,
`install-drupal-remote`, `remove-drupal`, `reinstall-drupal`,
`verify-drupal`, `clear-drupal-cache`, `publish-drupal-vhost`,
`smoke-test-drupal`, `admin-login-url`, `deploy-app-drupal`,
`destroy-app-drupal`, `verify-app-drupal`, `show-installed`,
`create-installed`. Migration Makefile: `restore-codebase`,
`restore-files`, `restore-private`, `migrate-db-all`.

DB-lifecycle already accept `DB=`: `db-backup`, `db-restore`,
`list-db-backups`, `delete-db-backup`.

### A.5 SSM & Secrets
Owned by `cf-app-drupal.yaml:176-263`: `/db-name`, `/db-user`,
`/site-name`, `/install-path`, `/admin-username`, `/admin-email`.
Read by: `install-drupal.sh:99-103`, `configure-php.sh:94-98`,
`Makefile:477,504,510,2793,2823,2884,2887`,
`publish-drupal-vhost.sh:61`, `publish-dns.sh:43`,
`unpublish-dns.sh:37`.

Secrets:
- `worxco/${env}/drupal/admin-password` — `cf-app-drupal.yaml:124`
- `worxco/${env}/drupal/db-password` — `:153`
- `worxco/${env}/drupal/hash-salt` — created by
  `install-drupal.sh:89,381-396`

### A.6 Migration
- Jumpbox `DRUPAL_ROOT="/var/www/html/zoning_info_platform"` —
  `dump-codebase.sh:74`, `dump-files.sh:62`, `dump-private.sh:60`
- S3 keys: `dumps/drupal-codebase.tar.gz`, `dumps/drupal-files.tar.gz`,
  `dumps/drupal-private.tar.gz`, `dumps/zinew.sql`
- `cf-migration/prod-mysql-zinew` — `migration/Makefile:114`
- `migrate-db-all` pins `ENV=sandbox` — `migration/Makefile:820-903`

---

## Appendix B — nginx/PHP Request Flow (from Explore agent, 2026-07-31)

### B.1 Full request path
`ALB → nginx (port 80) → NLB (9074 or 9083) → PHP-FPM (port 9000)`

- `cf-compute-alb.yaml:157–168` — ALB target group forwards to nginx
  on port 80; ELB health check hits `/health`
- `image-builder/configs/nginx/nginx.conf:84–103` — baseline nginx
  `listen 80 default_server` block owns `default_server` + serves
  `/health` locally + 404s everything else (decouples fleet health
  from Drupal install state)
- `nginx.conf:108` — `include /etc/nginx/shared/sites-enabled/*.conf`
  (multi-vhost-ready glob)
- `/etc/nginx/shared` is NFS mount of FSx subtree `/fsx/nginx`
  (mounted by `image-builder/components/install-nginx.yaml:176-178`)
- Vhost file today: `/fsx/nginx/sites-enabled/drupal.conf` — written
  by BOTH `scripts/publish-drupal-vhost.sh:70,79` AND
  `scripts/deploy-host/install-drupal.sh:656,660`

### B.2 PHP version selection
- `image-builder/components/install-nginx.yaml:186-195` —
  `configure-nginx.sh` writes `/etc/nginx/conf.d/upstream-php.conf`
  at boot with `upstream php74 { server $NLB:9074; }` and
  `upstream php83 { server $NLB:9083; }`
- `cf-compute-nlb.yaml:92-166` — NLB has TCP listeners 9074, 9083;
  each forwards to its own target group; both TGs point at PHP-FPM
  port 9000
- Two independent PHP ASGs (`cf-compute-php.yaml:278,316`) register
  into the target groups — one PHP 7.4 fleet, one PHP 8.3 fleet
- Vhost picks via `fastcgi_pass php83;` (or `php74;`) — hardcoded
  at `publish-drupal-vhost.sh:107` and `install-drupal.sh:694` to
  `php83`

### B.3 PHP-FPM env delivery
- `image-builder/configs/php/8.3/www.conf:9-46` (identical in 7.4/) —
  single pool `[www]`, `listen = 0.0.0.0:9000`, `clear_env = yes`
- `image-builder/configs/configure-php.sh:135-180` — at boot, reads
  SSM + Secrets Manager and rewrites a marker-delimited
  BEGIN/END worxco-boot block appended to `www.conf`, injecting
  `env[ENVIRONMENT_NAME]`, `env[DRUPAL_DB_HOST]`, `env[DRUPAL_DB_PORT]`,
  `env[DRUPAL_DB_NAME]`, `env[DRUPAL_DB_USER]`, `env[DRUPAL_DB_PASS]`,
  `env[DRUPAL_HASH_SALT]`, `env[AWS_S3_BUCKET]`,
  `env[DRUPAL_SITE_NAME]`, plus a `php_value[session.save_path]` for
  Valkey
- Comment at `configure-php.sh:32-35`: PHP-FPM does NOT accept
  `include=` inside a pool section, so per-site drop-ins would have
  to be separate pool blocks (not includes into `[www]`) — one reason
  tonight's decision picked `.env` + settings.php reading over
  pool-per-site

### B.4 AMI vs FSx split
Baked into nginx AMI:
- `/etc/nginx/nginx.conf` (default_server + health + include-glob
  framework)
- `/etc/nginx/conf.d/upstream-php.conf.template` (documentation only)
- `/opt/worxco/configure-nginx.sh`
- Empty `/etc/nginx/shared/sites-enabled/` directory (mount point)

Written to FSx at runtime:
- `/fsx/nginx/sites-enabled/*.conf` — vhost files (today only
  `drupal.conf` exists)

Baked into PHP AMIs:
- Base `www.conf`
- `/opt/worxco/configure-php.sh`
- `/opt/worxco/php-version` file
- Local `nginx` on port 9100 for FPM health checks

---

## Appendix C — Design Rationale Deep-Dives

### C.1 Why single-tree layout, not three siblings
Prior planning direction (from `docs/FSX-LAYOUT.md` at 2026-05-20):

```
/fsx/www/sites/<slug>/drupal/          ← Drupal install
/fsx/www/sites/<slug>/drupal-private/  ← private files
/fsx/www/sites/<slug>/drupal-config/   ← config sync
```

Tonight's direction:

```
/var/www/<site>/web/         ← Drupal docroot
/var/www/<site>/vendor/
/var/www/<site>/composer.json
/var/www/<site>/private/     ← private files
/var/www/<site>/config/      ← config sync
```

**Why single tree wins for tonight:**
- One `mv` or one ZFS snapshot moves/backs up/clones a site
- `du -sh /var/www/*/` gives per-site disk usage at a glance
- Backup script tars ONE dir per site
- No sibling-directory-name coupling to remember
- Matches Kurt's "adding a site name into our /var/www structure
  instead of just Drupal" ideation

**What prior direction did better:**
- Aligns with `sites/` prefix idiom (says "this dir contains
  tenants")
- Three sibling dirs allow different FSx snapshot policies per zone
  (code vs private files vs config) — but this project doesn't use
  that granularity anyway

### C.2 Why `.env` file, not `site-meta.yml` + Secrets Manager for MVP
Prior planning design (from `docs/FSX-LAYOUT.md § Per-site config`):

```yaml
# /fsx/www/sites/<slug>/site-meta.yml
site: { slug, uri, php_version }
database: { driver, host, name, user }   # NOT password
cache: { endpoint, port, tls }           # NOT auth_token
secrets:                                  # REFERENCES only
  db_password: worxco/<env>/sites/<slug>/db-password
  cache_auth_token: worxco/<env>/cache/auth-token
paths: { docroot, private, config_sync }
mail: { from, ses_smtp_endpoint }
```

Settings.php parses YAML, resolves secret references via AWS SDK,
caches result in APCu 60s.

Tonight's design:

```
# /var/www/<site>/.env
DRUPAL_DB_HOST=...
DRUPAL_DB_NAME=zoning_info_platform
DRUPAL_DB_PASSWORD=<literal-secret>
DRUPAL_HASH_SALT=<literal-secret>
AWS_S3_BUCKET=zoning-info-media-...
DRUPAL_PHP_VERSION=8.3
```

Settings.php parses `.env` (simple shell key=value or PHP-native
`parse_ini_file`), populates config directly. Zero AWS SDK, zero
APCu, zero YAML parser.

**Trade-off**:
- Prior design keeps secrets OFF FSx entirely (only references live
  on disk) + enables no-restart secret rotation (APCu cache expires
  within 60s of an SSM/Secrets Manager change)
- Tonight's design puts secrets ON FSx (mode 640, root:www-data —
  only root and PHP-FPM can read) + requires a
  `refresh-site-env.sh SITE=X` call to propagate a rotation (but
  the "call" is just writing one file on the deploy-host, and FSx
  is shared, so it's a single deploy-host action, not a fleet action)
- Tonight's design ships faster and is easier to reason about
- Prior design is a cleaner endpoint and is the Phase 5+ target

### C.3 Why single FPM pool, not pool-per-site
Pool-per-site would require:
- Each PHP-FPM instance runs N `[<site>]` pool blocks
- Each pool listens on its own port
- Each PHP fleet's NLB target group would need N listener/target
  pairs (one per site) — OR one big TG with all pools on the same
  instance and nginx `fastcgi_pass` picks by port
- Adding/removing a site requires FPM reload on every PHP-FPM box

Single pool with settings.php-based per-site config:
- One `[www]` pool per instance, unchanged
- Adding/removing a site requires ZERO PHP-FPM changes (just add
  a vhost + a `/var/www/<site>/` tree)
- Aligns with how Drupal (`settings.php`), WordPress (`wp-config.php`),
  and Laravel (`.env`) natively operate

The pool-per-site cost is high (NLB TG explosion, per-site config
per FPM box, ASG capacity math per site). The benefit (per-request
env-var-scope isolation) is unnecessary since settings.php already
provides per-request-scope isolation.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
