---
name: Drupal hash_salt persistence — migrated to Secrets Manager (transition in progress)
description: hash_salt now lives in Secrets Manager (worxco/$ENV/drupal/hash-salt) with a file fallback during transition. Historical context on why salt.txt was the wrong place, and the migration steps.
type: project
created: 2026-05-20
updated: 2026-07-20
---
# Drupal hash_salt persistence

## Status: PARTIALLY IMPLEMENTED (2026-07-20)

**Salt is now stored in Secrets Manager** at
`worxco/${ENV}/drupal/hash-salt`. The file at
`/var/www/drupal-private/salt.txt` is kept in sync during the
transition as a fallback for PHP-FPM instances that haven't yet
picked up the env-var-based config path.

Once all environments have been verified running with env-var-based
salt, the file (and its fallbacks in settings.php +
restore-private.sh's PRESERVE_FROM_BAK default) can be removed. That's
a follow-up commit.

## Historical context (why we moved)

Drupal's `hash_salt` originally lived only on FSx at
`/var/www/drupal-private/salt.txt`. FSx is part of `cf-storage`, which
gets destroyed by `make destroy-all`. **Every destroy/redeploy cycle
generated a new salt**, which invalidated every active Drupal session,
every pending password-reset link, every form-token-bearing in-flight
request, and every "remember me" cookie across the user base.

For sandbox/staging in active testing: probably fine — anyone logged
in expects to re-login after a teardown.

For production: **not OK**. A redeploy (planned or not) should not
log out every customer. salt should outlive the FSx volume.

## What hash_salt actually does in Drupal

From `Drupal\Core\Site\Settings::getHashSalt()`:

- Seeds session ID generation (so sessions can't be predicted)
- Seeds CSRF token generation (so tokens can't be forged across installs)
- Seeds one-time password-reset link tokens
- Seeds Drupal's form API token system
- Mixed into a few other cryptographic operations

If salt changes, anything generated with the old salt fails validation
under the new salt. Effect: existing sessions invalid, forms in
mid-submission fail, password-reset emails stop working, etc.

## Current state (2026-05-20)

- `install-drupal.sh` generates 64 hex chars of entropy via PHP's
  `random_bytes(32)` → writes to `$PRIVATE_DIR/salt.txt`
- Marker check: `if [ ! -f "$SALT_FILE" ]` skips regeneration if the
  file already exists
- File permissions: `root:www-data 0640` (just fixed today in
  commit 9d3425c)
- Lives on FSx → tied to the lifetime of the `cf-storage` stack
- destroy-all teardown destroys cf-storage → salt.txt destroyed →
  next install-drupal.sh generates a new one

## Proposed design — SSM SecureString

Move salt to SSM Parameter Store at:

```
/<env>/drupal/hash-salt          (SecureString, KMS-encrypted)
```

…or in the multi-tenant future:

```
/<env>/sites/<slug>/hash-salt    (SecureString)
```

`install-drupal.sh`'s salt step becomes:

```bash
SALT=$(aws ssm get-parameter --name "/$ENV/drupal/hash-salt" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
if [ -z "$SALT" ]; then
  SALT=$(php -r "echo bin2hex(random_bytes(32));")
  aws ssm put-parameter --name "/$ENV/drupal/hash-salt" \
    --value "$SALT" --type SecureString --overwrite=false
  log "Generated and stored new hash_salt in SSM"
else
  log "Reusing existing hash_salt from SSM"
fi
# Materialize on FSx so settings.php can read it fast (no SSM call per request)
echo "$SALT" | sudo tee "$SALT_FILE" > /dev/null
sudo chown root:www-data "$SALT_FILE"
sudo chmod 0640 "$SALT_FILE"
```

**Why materialize to FSx instead of having settings.php call SSM
directly:** Drupal calls `Settings::getHashSalt()` on every request.
SSM get-parameter is ~50-100ms; that would dominate request latency.
The FSx file is the local cache; SSM is the source of truth.

**Why SSM SecureString, not Secrets Manager:**
- Cost: SSM SecureString is free (KMS encryption only); Secrets
  Manager is $0.40/month per secret. We have 3+ envs × per-site
  multi-tenancy — that adds up.
- Auditing: both have CloudTrail integration.
- Rotation: Drupal doesn't rotate hash_salt (rotation invalidates
  everything), so Secrets Manager's rotation feature is unused.
- Pattern fit: SSM is where we put non-passwordy config + crypto
  material that doesn't need lifecycle management. Secrets Manager
  is where we put rotatable user-facing credentials (db passwords,
  admin passwords).

## Ownership question

Two options for who creates the SSM param:

(a) **cf-app-drupal stack owns it** (parallel to admin-password and
    db-password Secrets Manager entries). CFN creates the param
    with `Type: SecureString` and an initial value (could even use
    a Lambda-backed custom resource for the entropy, or pre-create
    with an empty value and let install-drupal.sh populate it).
    - Pro: consistent with how other Drupal secrets are managed
    - Con: CFN SecureString resources have edge cases (`NoEcho` doesn't
      help; the resource value lives in the CFN stack template).

(b) **install-drupal.sh owns it** (creates if missing, reads if
    present). cf-app-drupal doesn't know about it.
    - Pro: simpler; install-drupal.sh is already the place where
      salt is generated; SSM put-parameter is one extra line.
    - Con: salt's lifecycle isn't tied to cf-app-drupal's
      destroy-stack. If you destroy-app-drupal, the salt param
      survives. (Arguably this is FINE since you might want salt
      to outlive even the app-drupal stack — same recovery
      property as we want for destroy-all.)

Lean toward (b) for simplicity unless we find a reason to want
CFN-managed.

## Multi-tenancy interaction

Each site needs its own salt (otherwise compromise of one site's salt
compromises sessions/tokens for all sites). Path becomes
`/<env>/sites/<slug>/hash-salt`. Same pattern, per-site.

`site-meta.yml` (per `docs/FSX-LAYOUT.md`) should reference the salt's
SSM path the same way it references the DB password secret path —
non-secret reference, settings.php resolves at request time (with
APCu cache).

## When to implement

Two reasons to do this sooner rather than later:

1. **Before destroy-all becomes a thing operators do casually.** Right
   now we're treating destroy-all as a test fixture. As soon as
   destroy-all is used in production for ANY reason (e.g., region
   migration, account migration, big architecture refactor), the
   salt loss is a real outage.

2. **Before multi-tenant goes live.** The per-site salt design above
   is the time to put salt-in-SSM in place. Doing it once for all
   sites is cheaper than retrofitting later.

Tracking: `TODO.md` P1 entry. Captured 2026-05-20.

## Implementation checklist (for future-me)

When implementing:

- [ ] Update `install-drupal.sh` salt step (proposed code above)
- [ ] Update `FSX-LAYOUT.md` to reflect "salt.txt is a cache of SSM"
- [ ] Add `make rotate-salt ENV=<env>` for emergency salt rotation
      (compromise scenario only — knows it invalidates everything)
- [ ] Verify IAM: deploy-host role needs `ssm:GetParameter` +
      `ssm:PutParameter` on `/<env>/drupal/hash-salt`. PHP-FPM
      instance role doesn't need SSM access for this — they read
      the FSx-cached file.
- [ ] Test: destroy-all + deploy-allX twice; verify hash_salt is
      identical across both runs.
