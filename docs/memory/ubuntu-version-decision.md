---
name: Ubuntu version — on 24.04, 26.04 LTS spike deferred
description: Why all hosts stay on Ubuntu 24.04 LTS arm64; what touchpoints would change to move to 26.04 LTS once it's seasoned (~Aug 2026 / 26.04.1)
type: project
created: 2026-05-20
---
# Ubuntu version — current state and 26.04 deferral

## TL;DR

**All hosts (deploy-host, nginx fleet, PHP fleet) run Ubuntu 24.04 LTS
"Noble" on arm64. No Amazon Linux anywhere.** 26.04 LTS "Resolute" is
published as an AWS public AMI (since 2026-05-03) but the project
deliberately stays on 24.04 until 26.04.1 ships (~August 2026).

## Why all Ubuntu (and not Amazon Linux)

Pragmatic, not religious:
- Operator familiarity (Kurt has years of Ubuntu admin background).
- Drupal's standard composer/php-fpm stack is best-tested on Debian-family.
- Drush + Drupal community tooling assumes Debian/Ubuntu paths.
- Amazon Linux doesn't meaningfully reduce cost on EC2 (no licensing cost
  difference at the AMI level).
- One distro across all hosts means one set of conventions, one apt
  workflow, one package-name lookup.

This isn't a hard constraint — if a future requirement made Amazon
Linux attractive (e.g., better SSM integration in some specific
release), we could mix. Currently no driver.

## Why 24.04, not 26.04 (as of 2026-05-20)

- 26.04 LTS shipped April 2026; AWS public AMI first appeared 2026-05-03
  (Canonical's image: `ami-053da03328707680f`, description
  `"Canonical, Ubuntu, 26.04, arm64 resolute image"`).
- At time of writing, that's about 17 days old.
- New LTS `.0` releases reliably ship with kernel regressions, glibc
  surprises, and ecosystem-package version skew that bites operators
  who move on day one. Convention: wait for the `.1` point release
  (typically ~4 months after `.04`), where Canonical has rolled up
  initial bugfixes.
- 24.04 is supported free until 2029 and via Ubuntu Pro until 2034.
  No support-window urgency to move.

## Where the version is baked in (touchpoints for a future 24.04 → 26.04 spike)

Three places (verified by grep against the codebase 2026-05-20):

### 1. cf-deploy-host.yaml

```yaml
UbuntuAMI:
  Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
  Default: /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id
```

Change `24.04` → `26.04`. One line.

### 2. cf-image-builder.yaml — three pipeline recipes

```yaml
NginxRecipe:
  Properties:
    ParentImage: !Sub 'arn:aws:imagebuilder:${AWS::Region}:aws:image/ubuntu-server-24-lts-arm64/x.x.x'
PhpFpm74Recipe:
  Properties:
    ParentImage: !Sub 'arn:aws:imagebuilder:${AWS::Region}:aws:image/ubuntu-server-24-lts-arm64/x.x.x'
PhpFpm83Recipe:
  Properties:
    ParentImage: !Sub 'arn:aws:imagebuilder:${AWS::Region}:aws:image/ubuntu-server-24-lts-arm64/x.x.x'
```

Change `ubuntu-server-24-lts-arm64` → `ubuntu-server-26-lts-arm64`.
Three lines. **Verify the new alias exists in EC2 Image Builder's
catalog before deploying** (`aws imagebuilder list-images
--filters name=name,values="ubuntu-server-26*"`).

### 3. Codename in apt sources (nginx repo)

Both files reference `noble` (24.04's codename) in the nginx-stable
apt source:

- `image-builder/components/install-nginx.yaml:33`
- `cloudformation/cf-image-builder.yaml:418`

```
deb [signed-by=...] http://nginx.org/packages/ubuntu noble nginx
```

Change `noble` → `resolute` (26.04's codename, per Canonical's AMI
description). **High-risk touchpoint**: nginx.org/packages publishes
per-codename mirrors and CAN lag months behind a new Ubuntu LTS
release. If `resolute` mirror isn't ready when we spike, the AMI
bake will fail at the apt-update step.

Verification command (run before spike):
```bash
curl -sI http://nginx.org/packages/ubuntu/dists/resolute/Release \
  | head -1
# 200 OK = ready; 404 = not yet
```

If not ready: fall back options in priority order:
1. Use Ubuntu's `universe` nginx (older but always present —
   currently nginx 1.24 in noble; whatever's in resolute's universe).
2. Wait for nginx-stable to publish resolute mirror.

## What else might break on 26.04

Things to expect on a spike (most fixable):
- **PHP packages**: php7.4 may not be in Ubuntu 26.04's universe (php7.4
  was already deprecated upstream by 2024; 24.04 has it but 26.04 may
  drop it). If so, we need the ondrej/php PPA — same one we already
  may be using on 24.04 — but verify ondrej publishes for resolute.
- **systemd unit names**: PHP-FPM service names (`php8.3-fpm`,
  `php7.4-fpm`) may change if Ubuntu repackages.
- **Default `/etc/zsh/zshrc` content**: could differ; our append-if-not-
  present logic in bootstrap.sh is idempotent, so probably fine.
- **AWS SSM agent version**: 26.04 bundles a newer SSM agent; verify
  Session Manager + Run Command behave the same.
- **glibc version skew**: composer + drush should be unaffected
  (PHP-based, no native ext compilation). Watch any custom Drupal
  modules with C extensions.

## Suggested spike approach (when 26.04.1 ships, ~August 2026)

Don't change sandbox or production. Stand up a separate experimental
env (e.g., `sandbox26`) with its own VPC, FSx, RDS, and Image Builder
recipes. Run the full deploy-allX. Catalog any new gotchas. Compare
performance/cost. Then plan production migration with the spike's
lessons in hand.

## When to revisit

- **August 2026**: 26.04.1 should ship. Reconsider then.
- **If a critical security advisory** affects 24.04 in ways 26.04
  patches, revisit sooner.
- **If a Drupal/PHP version we need requires a newer-glibc base**,
  revisit (unlikely for PHP 8.3 / Drupal 11 line; possible for
  PHP 8.5 / 9.x in the future).

Tracking item: `TODO.md` P3 entry pointing at this memory.
