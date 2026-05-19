---
name: Post destroy-all residue inventory
description: What AWS resources survive `make destroy-all` and the open decisions about how to clean them up
type: project
---
# Post-`destroy-all` residue inventory

`make destroy-all` deletes the CloudFormation stacks listed in its target
(compute → image-builder → cache → database → storage → IAM → peering →
VPC) but explicitly preserves `cf-deploy-host` and `cf-app-drupal`. Even
within the destroyed stacks, AWS keeps several classes of artifact behind
that accumulate across destroy/deploy cycles.

This file inventories what was observed after the 2026-05-18 destroy-all
on the sandbox account, and captures the open design questions about
account hygiene.

## What's preserved on purpose (good — by design)

- **cf-deploy-host**: VM + its repo clone + SSH key. Survives so we don't
  have to re-bootstrap (apt installs, composer cache, etc.) on every cycle.
- **cf-app-drupal**: Secrets Manager entries for `worxco/<env>/drupal/*`
  + SSM params under `/<env>/drupal/`. Survives so passwords can be
  reused — the next `install-drupal` ALTERs postgres to match the
  existing secret rather than rotating.

## What's left behind by service (residue from torn-down stacks)

Observed post-destroy 2026-05-18:

- **RDS** — 3 snapshots + 2 recent events
  - Snapshots are *automatic* (final snapshot on stack delete, depending
    on DeletionProtection / SkipFinalSnapshot settings). These are
    real storage charges (GB-month).
- **FSx** — 10 backups
  - Backups persist after the filesystem itself is deleted. Charged per
    GB-month of backup storage.
- **EC2 Image Builder** — 17 image versions + 18 image workflows owned by us
  - Image versions accumulate per pipeline run. Each version references
    one or more AMIs (which are themselves separate residue — see below).
  - Workflows are the metadata about runs.
- **AMIs / EBS snapshots** (implied by image versions, worth verifying
  next pass) — every successful image build produces a `golden-AMI`
  whose backing EBS snapshot persists until the AMI is deregistered.
- **ElastiCache** — 14 events (informational; no $ impact)
- **CloudWatch** — log groups from compute + image-builder + RDS persist
  after their stacks are gone. Charged per GB-month of ingested log
  storage.

## One-time per-account setup that `destroy-all` doesn't undo

- **SSM "new experience"** activation is account-level, not stack-level.
  After a fresh account or some kind of console-level reset, AWS prompts
  to "Enable new experience" for Systems Manager. This is currently a
  one-time manual click in the console.
  - Open question: should `deploy-all` include a check (e.g.,
    `aws ssm get-service-setting`) that warns if not enabled?
  - Open question: does enabling "Configure Default Host Management
    Configuration" cost extra? Pricing basis unclear from the console.
  - Open question: should we enable "Just-in-time node access"?
  - Open question: which of the Node Tools (Compliance, Distributor,
    Fleet Manager, Hybrid Activations, Inventory, Patch Manager,
    Run Command, Session Manager, State Manager) do we actually need?
    We currently use Run Command + Session Manager. The rest are unknown.

## Design options for handling the residue

### Option A: `clean-account` target (sweep up the chads)

A new Make target that, after `destroy-all`, walks the residue list and
deletes:
- RDS snapshots older than N days (or all, by tag)
- FSx backups older than N days
- Old Image Builder image versions (keep latest M)
- Deregister orphan AMIs + delete their backing EBS snapshots
- CloudWatch log groups matching `/aws/<env>/*` patterns
- Old ElastiCache events (read-only? probably can't be deleted)

Pros: incremental, additive to existing destroy-all.
Cons: lots of small ad-hoc cleanup logic to maintain. AWS APIs for
"list all snapshots tagged X" vary by service.

### Option B: `destroy-all` vs `destroy-allX` split

Mirror the deploy-all / deploy-allX pattern:
- `destroy-all` = stacks only (current behavior)
- `destroy-allX` = stacks + CloudWatch logs + RDS snapshots + FSx
  backups + Image Builder versions + orphan AMIs. The "scorched earth"
  variant for "I'm done testing this account."

Pros: symmetric with deploy-all/deploy-allX. Clear opt-in semantics.
Cons: still requires the per-service cleanup logic from Option A.

### Option C: Burn-and-recreate the AWS account

The nuclear option. Account-level cleanup via Organizations:
1. Change the account's email address (to free the canonical address)
2. Close the account via Organizations
3. Create a new account with the original email address
4. Add the `OrganizationAccountAccessRole` IAM role so we can assume into
   the new account from the management account
5. Output the new `~/.aws/config` snippet for the new account number
6. Update any external references (CodeCommit URLs etc.) for the new
   account ID

Pros: definitive. Nothing escapes — no orphan snapshots, no SSM "new
experience" state, no console state, no IAM cruft. Cheaper than
chasing every AWS service's residue.

Cons:
- Requires Organizations parent account access + automation
- Account closure has a 90-day "suspended" waiting period before
  permanent deletion (the account can be reopened during that window)
- Account ID changes — every IAM trust policy that references this
  account ID anywhere must be updated
- External integrations (Bitbucket pipelines, GitHub Actions OIDC
  trust, third-party SaaS that's scoped to an AWS account ARN) all
  break

### Decision deferred

No action yet. Kurt's note 2026-05-19: "I don't want to do anything about
that at the moment, but you need to put that into memory somewhere, along
with a TODO to review it and make some decisions later." See TODO.md P3.

## Why this matters

Storage residue (RDS snapshots + FSx backups + EBS snapshots from old
AMIs + CloudWatch logs) is the silent cost-creep after a destroy. It
doesn't show up in stack-level cost reports because the stacks are
gone. A monthly Cost Explorer review will surface it but won't
automatically clean it up.
