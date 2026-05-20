---
name: Drush aliases for multi-tenancy — capture for future
description: Reference link + design notes for how Drush aliases work across many sites, and the open question about a single-place lookup pattern
type: project
created: 2026-05-20
---
# Drush aliases for multi-tenancy

## What this is

Notes captured for the future multi-tenant refactor (per
`docs/plans/multi-tenancy.md`). Not active work — this is a "when we
get there" reference so we don't have to rediscover the basics.

## Authoritative reference

**https://www.drush.org/13.7.3/site-aliases/**

This is Drush 13's site-aliases documentation. Version-pinned in the
URL — the link may need updating when we move to a newer Drush.
Check `vendor/bin/drush --version` for the active version when
revisiting.

## What a Drush alias is, in one paragraph

A site alias is a YAML record that tells Drush "the site I call
`@<alias>` lives at this URI, with this docroot, optionally on this
remote host." Files are typically named `<sitename>.site.yml` and
live in one of several discovery paths (project's `drush/sites/`,
system-wide `/etc/drush/sites/`, or per-user `~/.drush/sites/`).
Once registered, you can run `drush @client1.production cache:rebuild`
from the deploy-host (or from a developer's laptop with proper SSH
plumbing) and Drush figures out which site, which environment, and
how to reach it.

In our world, aliases are the natural primitive for "operate on site
X in env Y" — `drush @client1.sandbox cron`, `drush @client1.production
sql:dump`, etc. Without aliases, every Drush invocation in multi-tenant
land would need a `--root=/var/www/sites/client1/drupal/web --uri=...`
incantation.

## Open design question: single-location lookup across many sites

Kurt's framing (2026-05-20):

> At the end of the day, it would be nice to be able to go to a
> single location to find out about all aliases in a multi-tenancy
> environment. Worst case, we could create our own folder with hard
> links that put all the stuff in that place but point to the rest.
> It's hard to go out and create a brand new one in the artificial
> folder that we've created, because it's not going to know where to
> put the hard link to put it in a place that Drush is looking for.

What he's circling: when there are 50 sites, each with its own
`<slug>.site.yml`, where should those files live such that:

(a) Drush automatically discovers all of them from `drush sa` (site:alias) —
    i.e., the discovery path covers everything
(b) An operator can look in ONE place and see all sites
(c) When a new site is created, the new alias file lands in the right
    place automatically — no manual "remember to copy it"

### Discovery paths Drush 13 honors

Per the linked docs, Drush 13 searches these locations:
- `~/.drush/sites/` (per-user)
- `/etc/drush/sites/` (system-wide)
- `drush/sites/` inside the Drupal project root (relative to the
  composer.json the alias file is part of)

So for a multi-tenant setup where each site has its own composer
project at `/var/www/sites/<slug>/drupal/`, each site's alias would
naturally live at `/var/www/sites/<slug>/drupal/drush/sites/<slug>.site.yml`
— scattered. Drush discovers them as long as you `cd` into the right
project, but `drush sa` doesn't span sites.

### Possible designs

**(A) Aggregator in /etc/drush/sites/**
Every site's alias file gets symlinked (or hardlinked, as Kurt
suggested) into `/etc/drush/sites/<slug>.site.yml`. install-site
(future Make target) creates the link as part of site provisioning.
`drush sa` from anywhere on the deploy-host shows all sites.

Pro: single discovery path; matches Drush's own conventions; no
custom tooling.

Con: hard links across filesystems don't work (FSx vs deploy-host's
EBS for `/etc`). Symlinks work but operators have to know aliases
are "really" elsewhere. install-site has to remember to create the
link.

**(B) Aggregator in `/etc/worxco/aliases/` with explicit pointer**
Project-specific directory that mirrors the discovery semantics.
Drush is told to look there via a custom config in `~/.drush/`. We
control the structure entirely.

Pro: separates "Drupal's idea of where aliases live" from "our
operational view." Easier to swap implementations.

Con: requires Drush config plumbing; non-standard discovery path.

**(C) Generate aliases on demand**
A `make show-aliases ENV=<env>` target that walks `/var/www/sites/`
and prints/builds the alias YAML files on the fly. Or even better, a
Drush command extension that dynamically discovers sites.

Pro: no copies to keep in sync. Single source of truth (the per-site
directory structure itself).

Con: more code to maintain; not a "drush sa just works" experience.

**(D) Centralize alias files at install time, point at remote roots**
Each site's `<slug>.site.yml` lives ONLY in `/etc/drush/sites/` (or
similar central location). Its `root:` field points back at the
per-site Drupal install dir. No per-project drush/ subdir.

Pro: simplest discovery (single dir).

Con: violates Drush's "alias belongs with the project" convention; if
a site repo is moved/cloned elsewhere the alias is orphaned.

### Leaning

**Option A (symlinks into /etc/drush/sites/)** feels most consistent
with how Drush expects aliases to be discovered, AND gives Kurt the
"one place to look" experience he wants. The "hard links cross
filesystems" objection is sidestepped by using symlinks.

The install-site Make target (future) would create:
- `/var/www/sites/<slug>/drupal/drush/sites/<slug>.site.yml` (canonical,
  lives WITH the project — Drush's preferred convention)
- `/etc/drush/sites/<slug>.site.yml` → symlink to the above
  (aggregator view for `drush sa` across all sites)

destroy-site target removes both atomically.

But: this can change once we get there. Don't lock in now.

## Per-site alias content (sketch)

What goes IN each `<slug>.site.yml`:

```yaml
# /var/www/sites/client1/drupal/drush/sites/client1.site.yml
# (Also symlinked at /etc/drush/sites/client1.site.yml)

local:
  root: /var/www/sites/client1/drupal/web
  uri: https://client1.example.com
  paths:
    files: /var/www/sites/client1/drupal/web/sites/default/files
    private: /var/www/sites/client1/drupal-private/files
    config-sync: /var/www/sites/client1/drupal-config
  command-specific:
    # any client1-specific drush command overrides
```

For `drush @client1.production` style usage, we'd also have
environment-suffix aliases (or use environment-namespaced files like
`client1.production.site.yml`) — multi-env multi-site needs
careful naming convention.

## Tracking

- TODO P3 entry pointing at this memory.
- Implementation deferred to Phase E (multi-site refactor) per
  `docs/plans/multi-tenancy.md`.
- Revisit when we start the multi-tenant work. The actual decision on
  Option A vs B/C/D should be made with the per-site repo design from
  multi-tenancy.md in hand.
