---
name: Prefer structural correctness checks over metadata markers
description: When gating an operation on "is the system in state X?", check the actual structural signals (files/binaries that must be present, DB rows that must exist) rather than a metadata marker file whose presence is easy to lose. Marker files can be kept for informational value, but should not be the correctness gate.
type: project
created: 2026-07-17
---
# Prefer structural correctness checks over metadata markers

## TL;DR

Gate operations on **what must be true structurally** for the operation to
succeed — the presence of the actual binaries, config files, DB tables,
or services the operation will invoke. Do NOT gate on a metadata marker
file whose only purpose is to record "this was installed."

Marker files (e.g. `/var/www/drupal/.installed`) are fine to keep for
their informational value (install date, DB endpoint, secret paths,
audit trail), but their existence should never be the gate that lets
or blocks a downstream operation.

## Why this matters here

Discovered during the DB-only test migration on 2026-07-17. The sandbox
Drupal was installed successfully and serving traffic, but a
`sudo du -a /var/www | grep installed` showed **no `.installed`
file anywhere**. Reason: the install predated the marker convention.

The check `[ -f /var/www/drupal/.installed ]` — present in
`admin-login-url.sh`, `install-drupal-remote.sh`, `publish-drupal-vhost.sh`,
and `Makefile:verify-drupal` — produced FALSE NEGATIVES on this
functionally-working install:

    ERROR: Drupal not installed for env=sandbox (no .installed marker).

The user had to backfill the marker manually to unblock `make admin-login-url`.

## The pattern

**Instead of:**
```bash
if [ -f /var/www/drupal/.installed ]; then
  # proceed
fi
```

**Do:**
```bash
if [ -x /var/www/drupal/vendor/bin/drush ] \
   && [ -f /var/www/drupal/web/sites/default/settings.php ]; then
  # proceed — the actual preconditions for anything Drupal-shaped are met
fi
```

The structural check answers "can this operation work?" — which is what
we actually care about. It doesn't care WHY those files exist (install
script, restore from backup, manual composer install, git checkout,
whatever); the question is only "are they there?"

## Even better: symptom-driven

For operations that DO something with Drupal (drush, psql-env, etc.),
the strongest check is "attempt the operation, catch the specific
failure that means 'not installed', and translate to a user-friendly
error":

```bash
if ! /var/www/drupal/vendor/bin/drush status --format=json 2>/dev/null \
     | jq -e '.["bootstrap"] == "Successful"' >/dev/null; then
  echo "ERROR: drush cannot bootstrap Drupal. Is it installed at /var/www/drupal?"
  exit 1
fi
```

Zero false negatives, zero false positives. Cost: slower (drush runs
before the check completes), plus a jq dependency. Worth it for
operator-facing operations where the "yes/no" answer needs to be
authoritative.

## When markers are legitimate

Keep marker files for:
- **Informational content** — install timestamp, tool versions, config
  paths, audit info. Useful when SSH'd in and asking "when was this
  installed?"
- **Historical audit trail** — same as above, for compliance / traceability.
- **Cross-run signaling within a single script family** where you
  control both write and check. E.g., a bootstrap marker written at end
  of a first-boot script, read on next boot to decide "first-time init
  done, skip that block". Both sides are in your control.

Don't use markers for:
- Gating operations that could equally well check the actual precondition
- Signaling state across scripts that live in different pipelines /
  execution contexts
- Any check where a false negative silently blocks a legitimate operation

## Related

- `docs/memory/db-rollback-pattern.md` — same shape of principle (prefer
  the DIRECT operation over indirect proxies)
- Follow-up commit will fix the 4 marker checks currently in the
  codebase (`admin-login-url.sh:99`, `install-drupal-remote.sh:65`,
  `publish-drupal-vhost.sh` — grep for the actual line, `Makefile:1058`
  and neighbors)
- `scripts/deploy-host/install-drupal.sh:634-644` writes the marker with
  informational content. Keep this. Just don't gate on it.
