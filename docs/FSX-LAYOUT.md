---
name: FSx Layout
description: Authoritative reference for the FSx OpenZFS directory structure, mount model, file ownership, and the per-site config-on-FSx propagation pattern
audience: all
created: 2026-05-20
---
# FSx Layout

This document is the authoritative reference for how FSx OpenZFS is
organized across this project: directory structure, mount points,
ownership, and the per-site config-propagation pattern that lets us
change site configuration (including secrets) without restarting any
running compute.

If something here conflicts with another doc, this one wins.

## Volume model

**One FSx volume per environment.** Each environment (sandbox, staging,
production) has its own dedicated FSx OpenZFS file system created by
`cf-storage.yaml`. The volumes share nothing; an outage in one env's
FSx affects only that env. The environment name **does not appear
inside** the volume — it's enforced by which volume is mounted.

The FSx volume's internal root is `/fsx`. Everything below describes
what lives at `/fsx/...` on the volume itself.

## Mount points

The FSx volume exposes **two distinct mount sources** in the project:

| Mount source | Mount path | What it surfaces |
|---|---|---|
| `$FSX:/fsx` | `/var/www` | Volume root — full FSx tree visible to anyone who needs to read code, write site files, or manage the layout |
| `$FSX:/fsx/nginx` | `/etc/nginx/shared` | The nginx subtree, mounted at the path nginx's base config (`include /etc/nginx/shared/sites-enabled/*.conf`) expects to find vhost files |

**Both mounts are present on deploy-host and on nginx instances.**
PHP-FPM instances mount only `/var/www`.

| Host class | `df` entries | Why |
|---|---|---|
| **deploy-host** | 2 — `/var/www` AND `/etc/nginx/shared` | Operators see vhost configs at the SAME path nginx instances see them. Zero translation between "where I edit" and "where the runtime fleet reads." Also enables future local-nginx serve for sandbox testing without needing an AMI rebuild round-trip. |
| **PHP-FPM** | 1 — `/var/www` | Reads code, writes user-uploaded files. Doesn't read or care about the nginx config subtree. Second mount would be inert weight. |
| **NGINX** | 2 — `/var/www` AND `/etc/nginx/shared` | Same as deploy-host. `/var/www` for static-asset `try_files` serving; `/etc/nginx/shared` because that's the path the AMI-baked `nginx.conf` includes vhost configs from. |

The sub-mount (`$FSX:/fsx/nginx` at `/etc/nginx/shared`) and the root
mount (`$FSX:/fsx` at `/var/www`) are different access paths into the
same underlying FSx volume — not separate volumes. Operators can read
`/etc/nginx/shared/sites-enabled/drupal.conf` and
`/var/www/nginx/sites-enabled/drupal.conf` and see the same file
content; they're aliases via NFS export of overlapping subtrees.

**Why deploy-host gets both mounts (revised 2026-05-20):** earlier
design gave the deploy-host only `/var/www` since it COULD read the
nginx subtree as `/var/www/nginx/...`. Per-host-class mount-count
asymmetry caused operator confusion (debugging an nginx config issue
required mentally translating "where I'm editing on deploy-host" to
"where nginx reads on the runtime fleet"). The two-mount design
eliminates that translation step. Cost is one extra NFS mount and
fstab entry per env switch — trivially small.

No additional FSx mount points are needed anywhere. If a future
requirement looks like it needs a third mount source, the layout is
probably wrong — restructure subfolders first.

## Top-level directory structure

Under `/fsx/`:

```
/fsx/
├── sites/
│   ├── <site-slug-1>/                 ← one folder per Drupal site (multi-tenant)
│   │   ├── drupal/                    ← composer create-project drupal/recommended-project
│   │   │   ├── web/                   ← Drupal docroot (nginx points here)
│   │   │   ├── vendor/                ← composer deps
│   │   │   ├── composer.json
│   │   │   └── composer.lock
│   │   ├── drupal-private/            ← outside docroot; site's hash_salt + private files
│   │   │   ├── salt.txt               ← hash_salt; persists across reinstalls
│   │   │   └── files/                 ← Drupal "private://" file system
│   │   ├── drupal-config/             ← Drupal config-sync directory (export/import)
│   │   ├── site-meta.yml              ← non-secret site config (URI, db-name, php-version, etc.)
│   │   └── .installed                 ← marker; presence means install completed
│   ├── <site-slug-2>/
│   │   └── ...
│   └── default/                       ← single-site case lives here for layout consistency
│       └── ...
└── nginx/
    └── sites-enabled/
        ├── <site-slug-1>.conf         ← one vhost per site
        ├── <site-slug-2>.conf
        └── default.conf               ← fallback / single-site
```

**Key invariants:**

- **No `<env>` segment anywhere in the path.** The env is enforced by
  which FSx volume is mounted (each env gets its own volume); putting
  it in the path would be redundant and would break the
  env-portability of the codebase.
- **Single-tenant is just multi-tenant with N=1.** A single-site
  install lives at `/fsx/sites/default/` — same structure, no
  special case. Migrating today's `/fsx/drupal/` to
  `/fsx/sites/default/drupal/` is a future cleanup.
- **Each site is fully independent.** Its own composer install, its
  own vendor/, its own drupal-private/. Sites do not share a codebase.
  See `docs/plans/multi-tenancy.md` for the rationale.

## File ownership and permissions

Three principles govern who can read/write what:

1. **deploy-host is the only writer.** No production data path writes
   to FSx from a running compute instance. Sites are installed,
   updated, and modified via SSM dispatch to the deploy-host, which
   has the only `/var/www` mount where root has full write access.
2. **PHP-FPM workers can write only to per-site `files/` directories.**
   Drupal's "public://" file system (typically
   `<docroot>/sites/default/files/`) and "private://" file system
   (`<site>/drupal-private/files/`) are writable by `www-data`. Code
   and config are read-only.
3. **Secrets never live in FSx files.** Database passwords and other
   credentials live in AWS Secrets Manager. The per-site
   `site-meta.yml` on FSx contains only non-secret config (DB name,
   user, host endpoint, URI, PHP version) — never passwords.

| Path | Owner | Group | Mode | Writable by |
|---|---|---|---|---|
| `/fsx/sites/<slug>/drupal/web/` (except `files/`) | `root` | `www-data` | `0755` dirs, `0644` files | deploy-host only |
| `/fsx/sites/<slug>/drupal/web/sites/default/files/` | `www-data` | `www-data` | `0755` dirs, `0664` files | PHP-FPM workers (Drupal public://) |
| `/fsx/sites/<slug>/drupal-private/files/` | `www-data` | `www-data` | `0750` dirs, `0640` files | PHP-FPM workers (Drupal private://) |
| `/fsx/sites/<slug>/drupal-private/salt.txt` | `root` | `www-data` | `0640` | deploy-host only; read by settings.php |
| `/fsx/sites/<slug>/site-meta.yml` | `root` | `www-data` | `0640` | deploy-host only; read by settings.php + drush |
| `/fsx/nginx/sites-enabled/*.conf` | `root` | `root` | `0644` | deploy-host only; read by nginx |

## Per-site config: `site-meta.yml`

Each site has a `site-meta.yml` at `/fsx/sites/<slug>/site-meta.yml`
that's the **single source of truth for non-secret site config**.
Both Drupal's `settings.php` (at request time) and `drush` (at CLI
time) read it. Generated by the deploy-host when the site is
installed; rewritten by the deploy-host when site config changes.

Example:

```yaml
# /fsx/sites/client1/site-meta.yml
site:
  slug: client1
  uri: https://client1.example.com
  php_version: "8.3"

database:
  driver: pgsql
  host: sandbox-postgres.c256s2w8gam2.us-east-1.rds.amazonaws.com
  port: 5432
  name: drupal_client1
  user: drupal_client1_user
  # password: NOT here — fetched from Secrets Manager (see below)

cache:
  driver: redis
  endpoint: master.sandbox-cache.ka0pgy.use1.cache.amazonaws.com
  port: 6379
  tls: true
  # auth_token: NOT here — fetched from Secrets Manager

secrets:
  # SECRET REFERENCES (not values)
  db_password: worxco/sandbox/sites/client1/db-password
  cache_auth_token: worxco/sandbox/cache/auth-token  # shared per env
  admin_password: worxco/sandbox/sites/client1/admin-password

paths:
  docroot: /var/www/sites/client1/drupal/web
  private: /var/www/sites/client1/drupal-private
  config_sync: /var/www/sites/client1/drupal-config

mail:
  from: noreply@client1.example.com
  ses_smtp_endpoint: email-smtp.us-east-1.amazonaws.com
```

`settings.php` parses this and builds `$databases`, `$settings`, etc.
It then fetches the actual secret values from Secrets Manager using
the references in the `secrets:` block. Drush's alias file (also on
FSx, generated alongside `site-meta.yml`) consumes the same fields.

### Why YAML on FSx, not just SSM parameters?

- **Atomic per-site view.** One file change = entire site's config
  view changes consistently. SSM params are individual keys; a
  multi-key change isn't atomic without orchestration.
- **Drush can read it natively.** Drush 13's alias files are YAML.
- **Self-documenting.** Operators can `cat /fsx/sites/client1/site-meta.yml`
  to see everything about a site in one place.
- **Secrets stay out.** Only secret *references* live here; the
  actual values come from Secrets Manager at runtime.

## Secret propagation — how a config change reaches running workers

This is the design Kurt called out as critical: when a site is added
or a password rotates, **running PHP-FPM workers must pick up the
change without anyone restarting them.**

**The mechanism: settings.php reads site-meta.yml + Secrets Manager
on each request (with a short APCu cache).**

There is intentionally **no `env[]` in www.conf for per-site values**
in the multi-tenant model. The boot-time `env[]` approach (current
single-site model) doesn't work for multi-tenancy because:
- Workers are spawned once at boot with a frozen env;
- Adding a site mid-life doesn't reach those workers;
- Secret rotation mid-life doesn't reach those workers.

Instead:

1. **At request time**, nginx passes `SITE_SLUG=client1` as a
   `fastcgi_param` based on which vhost matched the Host header.
2. **settings.php** reads `/var/www/sites/$SITE_SLUG/site-meta.yml`
   via `yaml_parse_file()`, parses out non-secret config (DB host,
   name, user; cache endpoint; etc.).
3. **settings.php fetches secret values** from Secrets Manager using
   the IDs in the `secrets:` block. Uses the PHP AWS SDK (preferred)
   or shells out to `aws secretsmanager get-secret-value`. Caches in
   APCu with a 60-second TTL to avoid one Secrets Manager call per
   request — at our request volume that would be expensive and slow.
4. **Drupal proceeds** with the resolved config.

### Propagation flow for a secret rotation

```
operator: make rotate-site-secret SITE=client1 ENV=sandbox

  1. Generate new password (aws secretsmanager get-random-password)
  2. ALTER USER drupal_client1_user WITH PASSWORD '<new>' on RDS
     (via SSM to deploy-host)
  3. Update Secrets Manager: worxco/sandbox/sites/client1/db-password
     to the new value
  4. Optionally: bump a version stamp in site-meta.yml (so APCu cache
     is invalidated immediately rather than waiting up to 60s)

PHP-FPM workers (no restart):
  - Within ~60s (or immediately if step 4 used), next request reads
    fresh site-meta.yml and fresh Secrets Manager value
  - postgres now accepts only the new password; old in-flight queries
    using the old password might fail briefly — Drupal's auto-retry
    + the short window make this rarely visible

operator: nothing else to do. No restart-php-fpm. No reload-nginx.
```

### Propagation flow for adding a new site

```
operator: make install-site SITE=client2 ENV=sandbox DOMAIN=client2.com PHP=83

  1. Create drupal_client2 DB + drupal_client2_user in RDS
  2. Create site secrets in Secrets Manager
  3. composer create-project into /var/www/sites/client2/drupal
  4. Write /var/www/sites/client2/site-meta.yml
  5. Write /var/www/sites/client2/drupal-private/salt.txt
  6. drush site:install
  7. Write /fsx/nginx/sites-enabled/client2.conf — server_name client2.com
  8. make reload-nginx ENV=sandbox  ← REQUIRED: nginx needs reload to
                                      load the new vhost file
                                      (PHP-FPM does NOT need restart;
                                      first request to the new site
                                      will trigger settings.php to
                                      read the new site-meta.yml)
```

**Summary**: NGINX reloads when vhosts change (new site added/removed).
PHP-FPM does **not** restart for site config or secret changes — the
config-on-FSx + Secrets Manager + APCu cache loop handles everything.

The existing `make restart-php-fpm` target remains useful for one
case: when settings.php itself or other PHP code on FSx is updated
(OPcache holds the compiled version). For pure config/secret changes,
no PHP-FPM restart is needed.

## Backup model

Three classes of data, three backup strategies:

| Data | Where it lives | Backup mechanism | Granularity |
|---|---|---|---|
| **Database** | RDS PostgreSQL (one instance per env, multiple DBs per instance — one per site) | RDS automated snapshots + point-in-time recovery | Per-DB via `pg_dump`; per-env via snapshot |
| **Drupal codebase** | FSx under `/fsx/sites/<slug>/drupal/` | FSx OpenZFS snapshots (daily, 14-day retention) | Per-FSx-volume (per env) |
| **Customer assets** | FSx under `/fsx/sites/<slug>/drupal/web/sites/default/files/` and `/fsx/sites/<slug>/drupal-private/files/` | FSx snapshots **plus** per-site git delta capture to self-hosted GitLab CE (nightly cron from deploy-host) | Per-site, per-day deltas |

### Per-site customer-asset git capture

The customer-assets dimension deserves its own mechanism because:
- Customer asset directories must be `.gitignore`d in the code repo (don't mix code and uploads)
- They change frequently with small deltas (a few KB to MB per upload)
- They need a separate version-controlled audit trail

The historical pattern (Kurt's prior work): use `GIT_DIR` and
`GIT_WORK_TREE` env vars to point a git repo at the
`sites/default/files/` directory while keeping the `.git/` storage
on a separate volume. Nightly cron from the deploy-host does
`git add -A && git commit -m "$(date)" && git push <asset-remote>`
per site.

In our future stack:

- **Asset remote**: self-hosted GitLab CE on a small EC2 (already
  identified in multi-tenancy.md as the sovereign git host for code
  too — one host, two purposes).
- **GIT_DIR location**: not on FSx (don't backup the backup); on a
  dedicated EBS volume attached to the deploy-host. Sized
  appropriately for ~10x the active files volume (history adds up).
- **Schedule**: `cron` on the deploy-host runs the per-site
  capture nightly. Each site is a separate `.git` directory and a
  separate remote, so individual sites can be restored independently.

## Single-source-of-truth invariants (anti-drift rules)

To keep this layout from rotting:

1. **Paths never contain `<env>`.** If you see `/var/www/<env>/...`
   anywhere in templates, scripts, or docs, it's stale. The
   2026-05-15 cutover dropped this; new code must not reintroduce it.
2. **Secrets are never in FSx files.** Only secret *references* live
   in `site-meta.yml`. Actual values flow from Secrets Manager.
3. **deploy-host is the only writer to FSx** outside per-site
   `files/` directories. If a script running on nginx or PHP-FPM
   needs to write to FSx outside its allowed files dirs, the script
   is wrong.
4. **Each env has its own FSx volume.** Cross-env data flow on FSx
   would defeat the isolation. Migration tools that move data between
   envs do so via S3 or `pg_dump` — not by mounting two FSxs.
5. **No more than two logical FSx mount points exist in this
   project.** If a future requirement seems to need a third, the
   layout is wrong; either restructure subfolders or revisit the
   architecture.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
