---
name: SSM new experience decision — deliberately disabled
description: We turned off the AWS Systems Manager "new experience" (DHMC + Quick Setup) on 2026-05-19; if AWS prompts again, decline. Rationale + rollback playbook
type: project
---
# SSM new experience — deliberately disabled

## Decision (2026-05-19)

The AWS Systems Manager "new experience" / Integrated Console Experience
(which bundles **Default Host Management Configuration** + **Quick
Setup**-managed StackSets) is **deliberately OFF** in this account.

If AWS prompts to "Enable new experience" again in the console:
**decline.**

## What we use instead

Per-instance SSM access via explicit IAM roles in our CloudFormation:

- **Compute fleet** (nginx, php-fpm): instance role defined in
  `cf-iam.yaml`, with `AmazonSSMManagedInstanceCore` attached. Each ASG's
  launch template references this role.
- **Deploy-host**: instance role defined in `cf-deploy-host.yaml`,
  same `AmazonSSMManagedInstanceCore` policy.
- **Session Manager preferences**: managed via the
  `SSM-SessionManagerRunShell` document, created/owned by
  `cf-deploy-host.yaml`.

All three of these continue to work fine without the new experience.
SSM Session Manager and Run Command don't need DHMC or Quick Setup —
they're independent SSM services and have been working since SSM
existed.

## Why we said no

1. **Redundant with our existing model.** DHMC's value proposition is
   "auto-register every EC2 with SSM without per-instance IAM setup."
   We already do per-instance IAM setup explicitly in cf-iam.yaml —
   it's three lines, not painful. Dual management (IAM role *and*
   DHMC) can have surprising precedence behaviors when policies
   conflict.

2. **Implicit behavior.** Quick Setup turns on Patch Manager baselines,
   Inventory collection (writing to a new S3 bucket), State Manager
   associations, CloudWatch agent installs. Most are benign, but Patch
   Manager will flag our AMIs as "non-compliant" without context, and
   if anyone later flips on auto-remediation, OS patches land at AWS's
   chosen maintenance window — not ours. We bake AMIs deliberately via
   Image Builder; we don't want a parallel patching channel.

3. **Conflicts with the explicit-everything philosophy.** This project's
   stance is "no hidden state, everything in CFN, all permissions
   narrow and named." Quick Setup creates StackSets we didn't write,
   doing things we have to read AWS-supplied templates to understand.
   Wrong direction.

4. **Near-zero cost benefit.** Saves ~3 lines of IAM boilerplate per
   new compute stack. Not worth the complexity surface.

## When it MIGHT be worth revisiting

The one future scenario where DHMC could be net-positive is the
"burn-and-recreate the AWS account" hygiene path captured in
`docs/memory/destroy-all-residue.md` (Option C). On a fresh account
with no infrastructure, DHMC gives you SSM access to *any* EC2 the
moment you launch it, no IAM setup required. Useful as a bootstrap.

If we ever go down that path, this decision should be re-evaluated
in context — DHMC for the bootstrap window, then disable it once the
explicit cf-iam.yaml roles take over.

## How we rolled it back (2026-05-19)

History for future reference, in case it accidentally gets re-enabled:

1. AWS Systems Manager console → **Settings** (left sidebar, near bottom)
2. The "Integrated Systems Manager console experience" panel has an
   **Edit** and a **Disable** button. Click **Disable**.
3. Confirm in the dialog. AWS removes:
   - The `stackset-aws-quicksetup-ssm-<config>-<uuid>` StackSet instance
   - The `AWS-QuickSetup-SSM-LocalDeploymentRolesStack` (IAM
     bootstrap stack)
   - The S3 bucket created for SSM Inventory data
4. (Note: 2026-05-19 run — the S3 bucket auto-deleted, which was
   unexpected. AWS may have improved cleanup. If it persists in a
   future re-rollback, `aws s3 rb s3://<bucket> --force` it
   manually.)
5. Verify with:
   ```
   aws cloudformation list-stacks \
     --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_IN_PROGRESS \
     --query "StackSummaries[?contains(StackName,'QuickSetup') || \
              contains(StackName,'quicksetup')]"
   ```
   Should be empty.
6. Verify SSM access still works:
   ```
   aws ssm describe-instance-information \
     --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}'
   ```
   Should show all your managed instances Online.

## What this is NOT

- Not a rejection of SSM as a whole. Session Manager and Run Command
  are central to our access model (the deploy-host is reachable
  ONLY via Session Manager, no SSH ingress).
- Not a rejection of Patch Manager forever. If we want patch
  scanning later, we can wire it up explicitly via cf-iam.yaml +
  Patch Manager baselines we own, not via Quick Setup defaults.
