---
name: Infrastructure Gotchas
description: Hard-won lessons from deployment debugging — things that broke and why, to avoid repeating
type: project
originSessionId: f483de33-7dee-4185-b1a3-72a0ada5c58e
---
# Infrastructure Gotchas (Lessons Learned)

## CloudFormation

- **GroupDescription is immutable**: Changing `GroupDescription` on a security group forces REPLACEMENT. If `GroupName` is explicit, the new SG collides with the old name. Never change GroupDescription on deployed stacks — use option 3 (rename both GroupName + GroupDescription) or tear down first.

- **resolve:ssm is NOT re-evaluated on redeploy**: `{{resolve:ssm:/path}}` in templates only resolves when CloudFormation detects a resource change. Updating the SSM parameter value alone does NOT trigger re-resolution. Fix: use a `ForceUpdateToken` parameter referenced in a tag, pass `$(date +%s)` from Makefile.

- **Image Builder components are immutable**: Updating the CloudFormation template creates new component CONTENT, but the recipe continues using the old version until `RecipeVersion` is bumped in the parameter file. Always bump RecipeVersion when changing component content.

- **.env file format**: `.env` uses bare `KEY=VALUE` (no `export`). Make reads it via `-include .env` + bare `export`. Adding `export` keywords would break Make. For bash, use `set -a; source .env; set +a` or `export AWS_PROFILE=ZI-Sandbox` explicitly.

## VPC / Networking

- **VPC endpoints need BOTH AZs**: Interface endpoints (SSM, Secrets Manager) and Gateway endpoints (S3) must be in all AZs where instances run. Single-AZ endpoints cause failures for instances in the other AZ. Use `!If [HasTwoAZs, ...]` conditions.

- **S3 gateway endpoint uses public IPs**: Even though traffic routes through the VPC endpoint, S3 resolves to public IPs. Security groups need HTTPS egress to `0.0.0.0/0` (or the S3 prefix list), not just to the endpoint security group.

- **FSx NFS mount options**: The original tuned options (`nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,noatime`) cause "Operation not permitted" from cross-subnet instances. Simplified `vers=4.1,port=2049` works reliably across all subnets.

- **Private instances can't reach internet**: No NAT gateway by design. Outbound AWS API access via VPC endpoints only. Can't `apt-get`, `curl`, or `pip install` from private instances. Use S3 as a relay for files.

## SSM

- **Snap SSM agent ignores /etc/amazon/ssm/**: The snap-installed SSM agent on Ubuntu doesn't read config from `/etc/amazon/ssm/amazon-ssm-agent.json`. RunAs configuration must be done via account-level `SSM-SessionManagerRunShell` document instead.

- **SSM-SessionManagerRunShell is account-level**: This document affects ALL SSM sessions in the account, not just the deploy host. It must be deleted before stack deletion and recreated on deploy (Makefile handles this).

- **SSM sessions start as ssm-user by default**: Without the RunShell document, sessions land as `ssm-user` in `/var/snap/amazon-ssm-agent/`. The document configures `ubuntu` user with `cd ~ && exec bash -l`.

## IMDSv2

- **HttpTokens: required breaks IMDSv1 boot scripts**: If AMIs use `curl -s http://169.254.169.254/...` (IMDSv1), launch templates must set `HttpTokens: optional`. IMDSv2 requires token-based requests. Boot scripts updated in templates but need AMI rebuild to take effect.

## AWS Profile

- **ZI-Sandbox is account 033879516417**: The `ZI-Sandbox` AWS CLI profile assumes role into account 033879516417 via `OrganizationAccountAccessRole`. The parent account (645925380349, alias `worxco`) is the management account — NOT the sandbox.

- **Deploy host uses instance role, not profile**: No `~/.aws/credentials` needed. `AWS_DEFAULT_REGION` set via `/etc/profile.d/`. No `AWS_PROFILE` should be set.
