---
name: Drupal update management — Update Manager module deliberately disabled
description: Why install-drupal.sh uninstalls the Update Manager module, and the operator workflow for actually keeping Drupal patched
type: project
created: 2026-05-20
---
# Drupal update management

## The decision (2026-05-20)

**The Update Manager module is uninstalled at the end of every
`install-drupal.sh` run.** Future installs come up with it already off.
Operators do NOT re-enable it.

## Why

Drupal's Update Manager module assumes a traditional self-managed
Drupal install: the running webserver can reach updates.drupal.org,
the admin UI shows "X module has a new version available," and an
admin can click a button to download and apply the update.

**Every single piece of that assumption is false in this architecture:**

1. **No outbound internet from compute.** The PHP-FPM and nginx fleets
   are in private subnets with no NAT Gateway. VPC Endpoints cover
   our AWS API calls but don't reach the broader internet. updates.drupal.org
   is unreachable from any compute instance. Every page view that
   triggers an update check fails with cURL timeout (typically 30s
   to err out, then logged in watchdog).

2. **No in-place updates anyway.** Even if the compute fleet COULD
   reach updates.drupal.org, our deployment model is immutable AMIs +
   composer-managed codebase changes. Drupal code on FSx is owned by
   the install-drupal.sh process running on the deploy-host. An admin
   clicking "apply update" in the UI would (a) attempt to write to
   FSx as www-data (perms allow some writes but not module code), (b)
   succeed for that one webhead, (c) get overwritten the next time
   the instance refreshes (7-day max lifetime) since the AMI doesn't
   have the new code, (d) be inconsistent with other webheads in the
   fleet during the window.

3. **The warnings tell admins about something they cannot act on
   through Drupal.** That's worse than no information — it implies
   capability that doesn't exist, and trains users to ignore real
   warnings.

So: uninstall. The architectural posture is "Drupal does not
self-update. Operators update Drupal through the deploy-host."

## How operators actually check for and apply updates

This is the workflow that replaces the Update Manager UI:

### Checking for available updates

Run from the deploy-host (which DOES have internet via its peering
to the default VPC):

```bash
# Connect to the deploy-host
ssh sandbox     # or `aws ssm start-session --target <deploy-host>`

# Check available updates for Drupal core + contrib modules
cd /var/www/drupal
composer outdated --direct      # only top-level deps
composer outdated               # everything including transitive
```

Or query Drupal.org's release feeds directly:
- https://updates.drupal.org/release-history/drupal/current
- https://updates.drupal.org/release-history/<module-name>/current

Security-advisory subscription:
- https://www.drupal.org/security (RSS / mailing list)

### Applying an update

Updates are part of the **composer-on-deploy-host → commit → AMI bake →
instance refresh** cycle. The path:

1. On deploy-host: `composer update drupal/core --with-all-dependencies`
   (or whichever specific package). Verify locally — `drush updb -y`
   if there are pending DB updates, `drush cr` to clear caches.

2. Commit the resulting composer.lock to the per-site git repo
   (today single-site; future multi-tenant per-site repos).

3. Bump RecipeVersion in `cloudformation/parameters/image-builder-<env>.json`
   and `make build-amis ENV=<env>` to rebuild AMIs with the new code.

4. `make update-ami-params` + instance refresh on compute ASGs to
   roll the fleet.

5. Production: do all of the above against staging first, run the
   smoke test, then promote.

This is more steps than "click the green button" but it's the price
of immutable infrastructure with no in-place mutation.

## What if a security CVE drops and we need an emergency update?

Same workflow, expedited:
- On deploy-host: `composer require drupal/core:^11.3.12` (or whatever)
- Verify via drush
- Bake AMI, instance-refresh — about 30-45 min from `composer require`
  to fully-rolled-out fleet
- Production: at minimum hit staging first

For truly urgent CVEs (Drupalgeddon-class) where 30 min is too long,
the escape hatch is to hand-patch /var/www/drupal/ on FSx (it's NFS,
all compute sees the change immediately) and follow up with a proper
AMI bake. This is operator-only emergency procedure; we don't
advertise it because the hand-patched state doesn't survive AMI
refresh, and a forgotten follow-up bake means production reverts on
next instance cycle.

## Module-level updates (contrib modules + custom modules)

Same as core: composer-managed, AMI-baked. There is no "I can install
a module from the Drupal admin UI" path — that path would also need
internet access from compute, would write to FSx as www-data, and
would be wiped on next AMI cycle. Modules are added by editing
`composer.json` on the deploy-host and following the bake-and-roll
cycle.

## "But what about the admin UI? It's where Drupal admins look."

Drupal admins on this platform should know that the Reports → Available
updates page is unavailable by design. We should document this in the
operator-facing site README at install time (a TODO) so they don't
hunt for the page that isn't there.

The compensating mechanism is the deploy-host workflow above. It's a
process change for ops, not a UX regression for content editors
(content editors don't think about Drupal updates at all).

## What we are NOT doing (and why)

- **NOT keeping Update Manager + disabling automated cron**: would
  silence the immediate watchdog spam, but the admin UI would still
  show "no update info available" (also untrue — info would be
  stale, not unavailable). Less honest than uninstalling.

- **NOT running `drush cron` from the deploy-host periodically to
  refresh the update_status cache**: this would keep the admin UI
  populated with fresh info, but pretends Drupal "knows about
  updates" when really an external process is feeding it. Operators
  reading the UI would think clicking "apply update" would work; it
  wouldn't. Same lie-in-UI problem.

- **NOT setting up a different "do we need to update?" notification
  mechanism**: TODO territory. Possible options when we get there:
  Drupal.org security RSS → Lambda → SNS → operator email/Slack;
  or `composer outdated` run as a deploy-host cron with notification.

## Tracking

- Implementation: install-drupal.sh has `drush pm:uninstall update -y`
  as a final step after the install pipeline + permissions step
  (commit landing this memory).
- Future: a `make check-updates ENV=<env>` target that SSM-dispatches
  `composer outdated` on the deploy-host and prints the result. Would
  make "is there anything new?" a one-command operation instead of
  ssh + cd + composer.
