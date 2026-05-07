# Deploy Host Setup

This document describes the standalone deploy host for managing cf-scalable-web infrastructure deployments.

## Overview

The deploy host is a small EC2 instance that runs in the **default VPC**, separate from the project infrastructure. It is the **control plane** for both initial deployments and ongoing day-two Drupal operations:

- Long-running CloudFormation deployments (40+ minutes) without laptop dependency
- Persistent sessions via `tmux` or `screen`
- Survival across project VPC teardowns
- SSM Session Manager access (no inbound ports, no SSH)
- VPC peering to the project VPC for direct access to FSx, RDS, ElastiCache
- Full toolchain (composer, drush, psql, redis-cli, etc.) for Drupal codebase management

```mermaid
flowchart TB
    YOU[You / Laptop]

    subgraph DefaultVPC["Default VPC (172.31.0.0/16)"]
        DEPLOYHOST[Deploy Host<br/>t4g.small<br/>composer, drush, psql,<br/>redis-cli, helpers]
    end

    subgraph ProjectVPC["Project VPC (10.x.0.0/16, per environment)"]
        ALB[ALB]
        NGINX[NGINX Pool]
        NLB[NLB]
        PHP[PHP-FPM Pool]
        FSX[(FSx OpenZFS<br/>/var/www/&lt;env&gt;/drupal)]
        RDS[(RDS PostgreSQL)]
        CACHE[(ElastiCache Valkey)]
    end

    subgraph AWS["AWS Control Plane"]
        CF[CloudFormation]
        SM[Secrets Manager]
        SSMP[SSM Parameters]
    end

    YOU -->|SSM Session Manager| DEPLOYHOST
    DEPLOYHOST -->|make deploy-all| CF
    DEPLOYHOST -->|fetch credentials| SM
    DEPLOYHOST -->|read endpoints| SSMP
    DEPLOYHOST <==>|VPC Peering| FSX
    DEPLOYHOST <==>|VPC Peering| RDS
    DEPLOYHOST <==>|VPC Peering| CACHE
    CF --> ProjectVPC
    PHP -.NFS.-> FSX
    PHP -.SQL.-> RDS
    PHP -.cache.-> CACHE
    ALB --> NGINX --> NLB --> PHP

    classDef peering stroke:#ff9900,stroke-width:3px
    class DEPLOYHOST peering
```

## Architecture

| Component | Description |
|-----------|-------------|
| **Location** | Default VPC (always exists) |
| **Instance Type** | t4g.small (ARM, ~$6/month) |
| **OS** | Ubuntu 24.04 LTS |
| **Access** | SSM Session Manager only (no inbound ports) |
| **Public IP** | Dynamic (outbound internet only, no EIP) |
| **IAM Role** | AdministratorAccess via instance role (no access keys) |
| **VPC Peering** | One peering connection per project environment (sandbox, staging, production) — see `cf-deploy-peering.yaml` |
| **FSx Access** | Mounts FSx at `/var/www/<env>/` via the `mount-env` helper (NFS over VPC peering) |
| **DB Access** | `psql-env <env>` resolves the RDS endpoint and master password automatically |
| **Cache Access** | `valkey-env <env>` resolves the Valkey endpoint and AUTH token (TLS) automatically |

### Why Separate from Project VPC?

1. **Survivability**: Project VPC can be destroyed/recreated without affecting the deploy host
2. **Independence**: Deploy host doesn't depend on project infrastructure
3. **Simplicity**: No circular dependencies during initial deployment
4. **Internet egress**: PHP-FPM instances are intentionally sealed (no NAT, no IGW route). The deploy host is the **only** instance with general internet access — the gateway through which composer packages, npm modules, and other external code enter the system.

### VPC Peering (per-environment)

Once both the deploy host and a project VPC exist, `make deploy-peering ENV=<env>` builds a peering connection that gives the deploy host direct network access to the project's data plane. See `cf-deploy-peering.yaml` and the per-environment Make target.

```
Default VPC (172.31.0.0/16)  <==peering==>  Project VPC (10.200.0.0/16  for sandbox)
                                            Project VPC (10.102.0.0/16  for staging)
                                            Project VPC (10.101.0.0/16  for production)
```

The peering enables:
- NFS to FSx OpenZFS (port 2049)
- PostgreSQL to RDS (port 5432)
- TLS Valkey to ElastiCache (port 6379)

**FSx hostname caveat**: FSx OpenZFS DNS records live only in the project VPC's internal resolver and do **not** resolve across peering even with `AllowDnsResolutionFromRemoteVpc=true`. The `refresh-env-config` helper bridges this by maintaining `/etc/hosts` entries (managed block, FSx hostname → private IP) on the deploy host. Run after destroy/redeploy: `sudo refresh-env-config <env>`.

## Control Plane vs. Data Plane

The system splits into two roles that share the same underlying storage and database, but have very different network postures and capabilities:

| Role | Where it lives | What it does | Internet egress | Mounts FSx | Talks to RDS | Sees AWS APIs |
|------|---------------|--------------|-----------------|------------|--------------|---------------|
| **Data plane**<br/>(serves traffic) | PHP-FPM auto-scaling group in the project VPC | Reads code from FSx, queries RDS, caches in Valkey, returns HTTP responses through NLB → NGINX → ALB | **No** — sealed for security | Yes (mounted on every PHP instance at boot) | Yes | Only via VPC endpoints (SSM, Secrets Manager, S3) |
| **Control plane**<br/>(manages code) | Deploy host in the default VPC | Runs CloudFormation, fetches packages from internet, writes Drupal code to FSx, runs `drush` against RDS, manages config | **Yes** — full egress | Yes (via `mount-env`) | Yes (via VPC peering) | Yes (full AWS API access) |

Both planes touch the **same FSx volume and same RDS database**. When the deploy host writes code into FSx (e.g., `composer require drupal/admin_toolbar`), every PHP-FPM instance sees the new files on its NFS mount automatically — no coordination, no rotation, no SSH-into-PHP needed.

### Why this split matters

This is the core architectural reason the deploy host exists. The PHP-FPM data plane is **deliberately sealed from the internet** to reduce attack surface: a compromised PHP process can't `curl evil.com`, can't pull a rogue dependency, can't exfiltrate data via outbound HTTP. But Drupal sites still need new modules, security patches, and codebase updates over time — those have to enter the system somehow.

The deploy host is that controlled, audited entry point:
- Has internet access for fetching packages (composer, npm, etc.)
- Has FSx mount for writing code into the shared volume
- Has VPC peering for managing the database (drush updb, config changes, etc.)
- Is reachable only via SSM Session Manager (every action audited via CloudTrail)
- Has no public web port — it can't accidentally serve traffic

Most teams refactor toward this shape after a security review forces them to. We started with it because the project's no-NAT design made it a natural consequence of the constraints.

## Day-Two Operations

After the initial deployment, **all** Drupal codebase and database management happens via the deploy host. The PHP-FPM instances stay sealed; new code flows in through FSx writes from the deploy host.

### Installing a Drupal module

```bash
ssh deploy-host                                  # SSM-via-SSH tunnel
sudo mount-env sandbox                           # mounts FSx at /var/www/sandbox
cd /var/www/sandbox/drupal

composer require drupal/admin_toolbar            # composer fetches from packagist
                                                 # writes module to FSx
                                                 # PHP-FPM instances see it immediately

drush en admin_toolbar -y                        # enables module (writes to RDS via peering)
drush cr                                         # clear caches (Valkey via peering)

# Done. The next public ALB request serves the new module.
```

No restart, no instance rotation, no downtime. The PHP-FPM auto-scaling group is unaware anything happened — it just notices new files on FSx and serves them.

### Database operations

```bash
# Quick query
psql-env sandbox -c "SELECT count(*) FROM users_field_data;"

# Drupal-aware operations
cd /var/www/sandbox/drupal
drush sql:dump > /tmp/sandbox-backup.sql
drush sql:cli                                    # interactive PostgreSQL prompt
drush sqlq "SELECT name FROM users_field_data;"  # one-off SQL via drush
```

### Cache operations

```bash
valkey-env sandbox PING                          # health check
valkey-env sandbox INFO server                   # server stats
valkey-env sandbox FLUSHDB                       # nuclear option (don't do casually)

# From inside Drupal
cd /var/www/sandbox/drupal
drush cr                                         # rebuild Drupal caches
```

### Config management

```bash
cd /var/www/sandbox/drupal
drush cex -y                                     # export current config to filesystem
drush cim -y                                     # import config from filesystem to DB
git -C /var/www/sandbox/drupal/config diff       # what changed
```

### Browse the production site through the deploy host (drush runserver)

`drush runserver` (or `drush rs`) starts a development PHP server backed by the actual codebase and database. It's slow and single-threaded, but useful for:

- **Pre-flight testing**: see how a new module renders before public traffic does
- **Maintenance windows**: do `/admin/structure/...` work without exposing it to public ALB traffic
- **Forensics**: live-debug a production issue against actual production data
- **Quick previews**: browse changes immediately after `drush cim` or `composer require`

The deploy host has no inbound port 8080, so use SSH local port forwarding to reach it from your Mac:

**On the deploy host** (one terminal — leave running):
```bash
sudo mount-env sandbox
cd /var/www/sandbox/drupal
vendor/bin/drush runserver 0.0.0.0:8080
# Output: HTTP server listening on 0.0.0.0, port 8080
```

**On your Mac** (another terminal — leave running):
```bash
ssh -L 8080:localhost:8080 deploy-host
# This blocks; the tunnel is up while it's open
```

**Then in your Mac browser**:
```
http://localhost:8080
```

The traffic path: `Mac browser → Mac:8080 → SSH/SSM tunnel → deploy-host:8080 → drush runserver → Drupal (FSx + RDS + Valkey)`.

You're seeing the same data the public ALB serves, but through a one-person tunnel instead of the public internet. Excellent for "test on real data without exposing the test."

To keep `drush runserver` alive across SSM session disconnects, run it inside `tmux`:

```bash
tmux new -s drupal
cd /var/www/sandbox/drupal && vendor/bin/drush runserver 0.0.0.0:8080
# Ctrl-B then D to detach (server keeps running)
# Later: tmux attach -t drupal
```

## Prerequisites

1. **AWS Account**: With default VPC intact
2. **AWS CLI**: Configured on your laptop for initial deploy
3. **Session Manager Plugin**: Installed locally (`brew install session-manager-plugin` on macOS)
4. **Secrets Manager** (optional): GitHub deploy key at `worxco/deploy-host/github-ssh-key` for automatic repo cloning

## Deployment

### 1. Deploy

```bash
make deploy-deploy-host
```

The only configurable parameter is `InstanceType` (default: `t4g.micro`). There are no key pairs, no SSH CIDR rules, and no inbound ports to configure.

This will:
- Create a security group with no inbound rules (all ingress blocked)
- Create an IAM role with SSM and AdministratorAccess policies
- Create an SSM-SessionManagerRunShell document (sessions run as `ubuntu` with bash login shell)
- Launch an EC2 instance with all tools pre-installed
- Auto-configure GitHub deploy key from Secrets Manager (if the secret exists)
- Auto-clone the repository and set up `.env` from `.env.example` (if the deploy key is configured)

### 2. Get Connection Info

```bash
make verify-deploy-host
```

Outputs include:
- `DeployHostInstanceId`: Instance ID for SSM sessions
- `DeployHostPublicIP`: Dynamic public IP (outbound only, no inbound ports open)
- `SSMCommand`: Ready-to-use SSM Session Manager command

### 3. Connect

```bash
aws ssm start-session --target i-XXXXXXXXX
```

The SSM-SessionManagerRunShell document configures sessions to run as the `ubuntu` user with a bash login shell. You land directly in the ubuntu home directory with environment variables loaded.

## GitHub Deploy Key (Auto-Configuration)

On boot, the instance retrieves a GitHub SSH deploy key from AWS Secrets Manager at the path `worxco/deploy-host/github-ssh-key`. The secret must be a JSON object with two fields:

```json
{
  "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n",
  "public_key": "ssh-ed25519 AAAA... deploy-host"
}
```

When the secret exists, the bootstrap script:
1. Writes the key pair to `/home/ubuntu/.ssh/github_deploy_key` (and `.pub`)
2. Configures `/home/ubuntu/.ssh/config` to use the key for `github.com`
3. Clones the repository to `~/projects/cf-scalable-web`
4. Copies `.env.example` to `.env`

If the secret does not exist, bootstrap continues without error. You can clone the repo manually later.

## Auto-Clone and Environment Setup

When the GitHub deploy key is available, the repository is cloned automatically during bootstrap. On first SSM session, you land with the repo ready:

```bash
cd ~/projects/cf-scalable-web
tmux new -s deploy
make deploy-all ENV=sandbox
```

No manual `git clone` is needed.

## Usage

### Quick Start

```bash
# Connect via SSM
aws ssm start-session --target i-XXXXXXXXX

# Repo is already cloned and .env is configured
cd ~/projects/cf-scalable-web
tmux new -s deploy

# Run deployment
make deploy-all ENV=sandbox

# Detach and go home
# Press: Ctrl-B, then D

# Later, reconnect
aws ssm start-session --target i-XXXXXXXXX
tmux attach -t deploy
```

### SSM Session Manager Details

- All sessions are logged to CloudTrail
- Sessions run as `ubuntu` with a bash login shell (configured via the SSM-SessionManagerRunShell document)
- Environment variables (`AWS_PAGER`, `AWS_CLI_AUTO_PROMPT`, `AWS_DEFAULT_REGION`, `EDITOR`) are set via `/etc/profile.d/deploy-host-env.sh`
- AWS credentials come from the instance role via IMDS (no access key files)

## Pre-Installed Tools

Installed by `scripts/deploy-host/bootstrap.sh` (sourced from this repo) on first boot. Re-runnable manually for tool refreshes without instance replacement: `sudo bash scripts/deploy-host/bootstrap.sh`.

### Core operations

| Tool | Purpose |
|------|---------|
| `aws` | AWS CLI v2 (ARM64) |
| `git` | Version control |
| `make` | Build automation |
| `tmux` / `screen` | Persistent sessions |
| `vim` | Text editor (set as default) |
| `tree` | Directory visualization |
| `jq` | JSON processing |
| `cfn-lint` | CloudFormation linting (installed in /opt/cfn-lint venv) |
| `claude` | Claude Code CLI |
| `node` / `npm` | Node.js 20.x LTS runtime |
| `session-manager-plugin` | AWS Session Manager plugin (better SSM CLI) |

### Drupal management toolchain (Phase B)

| Tool | Purpose |
|------|---------|
| `nfs-common` | Mount FSx OpenZFS |
| `postgresql-client` | `psql` for RDS access |
| `sqlite3` + `php8.3-sqlite3` | Local Drupal install for fast iteration |
| `redis-tools` | `redis-cli` (wire-compatible with Valkey) |
| `php8.3-cli` + 12 extensions | PHP runtime: cli, common, curl, mbstring, xml, zip, gd, pgsql, sqlite3, intl, bcmath, opcache |
| `composer` | Dependency manager (latest stable from getcomposer.org) |
| `drush` | Drupal CLI (composer global, in `~/.config/composer/vendor/bin`) |

### Helpers (in `/usr/local/bin` and `/usr/local/sbin`)

All defined in `scripts/deploy-host/` in this repo, installed by bootstrap.

| Helper | Purpose |
|--------|---------|
| `info-env <env>` | Print live RDS, FSx, Valkey, ALB endpoints from SSM |
| `show-env <env>` | Pretty-print the cached endpoint config |
| `sudo refresh-env-config [envs...]` | Regenerate `/etc/worxco/envs/<env>` and `/etc/hosts` FSx block from SSM. NOPASSWD via sudoers.d. |
| `sudo mount-env <env>` | Mount FSx OpenZFS at `/var/www/<env>` |
| `psql-env <env> [args]` | psql wrapper that auto-resolves endpoint and master password |
| `valkey-env <env> [args]` | redis-cli wrapper that auto-resolves endpoint, AUTH token, and TLS |

### State files

| File | Purpose |
|------|---------|
| `/etc/worxco/deploy-host-marker` | Used by Make targets and scripts to detect "running on the deploy host" vs "running on a developer's Mac" |
| `/etc/worxco/envs/<env>` | Sourceable shell config (DRUPAL_ENV, RDS_ENDPOINT, FSX_DNS, VALKEY_HOST, ALB_DNS, ...) |
| `/etc/hosts` (managed block) | FSx hostname → private IP entries, between `# BEGIN/END worxco-fsx-hosts` markers |
| `/var/log/deploy-host-bootstrap.log` | Full UserData + bootstrap.sh trace (with `set -x`) — local to instance, lost on replacement |

## Security

### No Inbound Ports

The security group has **zero ingress rules**. All inbound traffic is blocked. Access is exclusively through SSM Session Manager, which uses an outbound HTTPS connection from the instance to the SSM service endpoint.

### SSM Session Manager

- Provides shell access without any open ports
- All sessions logged to CloudTrail
- No key pairs, no passwords, no SSH
- Session preferences configured via SSM-SessionManagerRunShell document at the account level

### IAM Role

The deploy host has `AdministratorAccess` for infrastructure management. This is intentional -- it needs to create/modify all AWS resources including IAM roles and policies. No access keys are stored on the instance; credentials come from the instance role via IMDS.

### Root Password

An optional root password can be stored in Secrets Manager at `worxco/deploy-host/root-password`. If present, it is set during bootstrap. If absent, bootstrap continues without error.

## Teardown

```bash
make destroy-deploy-host
```

This deletes:
- EC2 instance
- Security group
- IAM role and instance profile
- SSM-SessionManagerRunShell document

## Troubleshooting

### SSM Session Fails to Connect

1. Verify the instance is running: `aws ec2 describe-instance-status --instance-ids i-XXXXXXXX`
2. Confirm the SSM agent is running (check console output if needed)
3. Ensure the Session Manager Plugin is installed locally: `session-manager-plugin --version`
4. Verify the instance has a public IP for outbound HTTPS to the SSM endpoint

### Instance Not Responding

```bash
# Check instance status
aws ec2 describe-instance-status --instance-ids i-XXXXXXXX

# View console output
aws ec2 get-console-output --instance-id i-XXXXXXXX --output text
```

### Bootstrap Failed

Connect via SSM and check:
```bash
cat /var/log/deploy-host-bootstrap.log
cat /var/log/deploy-host-bootstrap-status
```

If bootstrap-status does not contain `SUCCESS`, review the log for errors the bootstrap script encountered.

### Repository Not Cloned

If the repo was not cloned automatically, verify the Secrets Manager secret:

```bash
aws secretsmanager get-secret-value \
  --secret-id "worxco/deploy-host/github-ssh-key" \
  --query 'SecretString' --output text | python3 -c "import json,sys; print(json.load(sys.stdin).keys())"
```

The secret must contain `private_key` and `public_key` fields. After adding or fixing the secret, either redeploy or manually configure SSH:

```bash
# On the deploy host
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Paste the private key into ~/.ssh/github_deploy_key
chmod 600 ~/.ssh/github_deploy_key
git clone git@github.com:worx/cf-scalable-web.git ~/projects/cf-scalable-web
```

## Cost

| Resource | Monthly Cost |
|----------|--------------|
| t4g.micro (on-demand) | ~$6.00 |
| EBS (20GB gp3, encrypted) | ~$1.60 |
| **Total** | **~$7.60/month** |

Stop the instance when not in use to save on compute costs:

```bash
make stop-deploy-host    # Stop instance
make start-deploy-host   # Start instance
```

When stopped, only the EBS volume incurs charges (~$1.60/month).

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** (C) 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
