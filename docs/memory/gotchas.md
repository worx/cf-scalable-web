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

## Deploy Host Lifecycle

- **`make deploy-deploy-host` ALWAYS replaces the EC2 instance** — even for output-only template changes. The UserData has tokens/timestamps that change each deploy, so CloudFormation tears down the old instance and launches a new one. **Do not run `make deploy-deploy-host` from a shell on the deploy host itself** — your SSM session dies with the box. Run it from your Mac (or another machine) instead. The new instance auto-clones the repo and is functionally identical to the old one. Discovered 2026-05-06 during VPC peering rollout.

- **`!Ref` on AWS::EC2::SecurityGroup without explicit VpcId returns the GroupName, not the GroupId**: Legacy EC2-Classic Ref behavior that AWS still falls back to when `VpcId` is unspecified, even though EC2-Classic itself was retired in 2022. The SG resource is created in the default VPC, but `!Ref` returns the literal name string (e.g., `cf-deploy-host-sg`), which is invalid wherever an `sg-xxxxxxxxx` ID is expected. **Fix**: always use `!GetAtt MySecurityGroup.GroupId` for outputs/exports — works regardless of how the SG was created. Discovered 2026-05-06 when cf-deploy-peering's `SourceSecurityGroupId` rules failed with `Invalid id: cf-deploy-host-sg (expecting sg-...)`.

- **AWS-managed RDS master credentials are stored as JSON, not plaintext**: When RDS is configured with `ManageMasterUserPassword: true`, AWS creates a Secrets Manager entry with structure `{"username":"dbadmin","password":"..."}` — NOT a plaintext password. Symptom: `psql` connection fails with `password authentication failed for user "dbadmin"` because the entire JSON blob is being passed as the password. **Fix**: scripts that fetch the master password must extract `.password` via `jq`. The defensive pattern that handles both AWS-managed (JSON) and hand-created (plaintext) secrets:
  ```bash
  RAW=$(aws secretsmanager get-secret-value --secret-id $ID --query SecretString --output text)
  PASS=$(echo "$RAW" | jq -r '.password // empty' 2>/dev/null || true)
  [ -z "$PASS" ] && PASS="$RAW"
  ```
  Applied 2026-05-08 to psql-env, valkey-env, install-drupal.sh, remove-drupal.sh, and the Makefile verify-drupal target.

- **VPC peering does NOT enable cross-VPC DNS resolution by default**: After `aws ec2 create-vpc-peering-connection`, instances in one VPC can route packets to the other, but they CANNOT resolve the peer VPC's private DNS names. RDS and ElastiCache work across peering anyway because their hostnames are AWS-public DNS that resolve to private IPs via split-horizon (works from any VPC). **FSx is the exception — its hostname is resolvable only from within its home VPC's internal resolver, even with `AllowDnsResolutionFromRemoteVpc=true` set on the peering connection**. The flag controls Route 53 private hosted zones; FSx OpenZFS uses VPC-internal DNS, which is not affected by the flag. Setting the flag is still required (and `make deploy-peering` does it automatically) for any future Route 53 private zones, but it does NOT solve FSx. **Solution**: maintain `/etc/hosts` entries on the deploy host mapping each FSx hostname → private IP. The IP is stable for SINGLE_AZ_1 deployments. The `refresh-env-config` script does this automatically — looks up `aws fsx describe-file-systems` → `aws ec2 describe-network-interfaces` to find the private IP and rewrites a managed block in `/etc/hosts` (between `# BEGIN/END worxco-fsx-hosts` markers). Discovered 2026-05-06 during peering connectivity testing.

- **Unconditional pre-delete of `SSM-SessionManagerRunShell` silently breaks SSM sessions**: Earlier versions of `make deploy-deploy-host` always pre-deleted the SSM document before running CloudFormation. CFN's stack state already had `SSMSessionPreferences` as `CREATE_COMPLETE` and saw no template change, so it did nothing — leaving the stack happy but the document gone. Result: SSM sessions fall back to default `ssm-user` with `sh` instead of `ubuntu` with `bash`. **Fix** (2026-05-06): pre-delete only when the stack does NOT yet exist (orphan cleanup case). When the stack exists, CFN already owns the document. **Recovery for orphaned state**: manually `aws ssm create-document --name SSM-SessionManagerRunShell` with the same content as the template — CFN's physical-id is just the document name, so re-creating it puts CFN's state back in sync.
