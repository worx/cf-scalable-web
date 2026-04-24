# Deploy Host Setup

This document describes the standalone deploy host for managing cf-scalable-web infrastructure deployments.

## Overview

The deploy host is a small EC2 instance that runs in the **default VPC**, separate from the project infrastructure. This design allows:

- Long-running deployments (40+ minutes) without laptop dependency
- Persistent sessions via `tmux` or `screen`
- Survival across project VPC teardowns
- SSM Session Manager access (no inbound ports, no SSH)

```mermaid
flowchart TB
    subgraph Internet
        YOU[You / Laptop]
    end

    subgraph DefaultVPC["Default VPC"]
        DEPLOYHOST[Deploy Host<br/>t4g.micro]
    end

    subgraph ProjectVPC["cf-scalable-web VPC"]
        NGINX[NGINX]
        PHP[PHP-FPM]
        RDS[(RDS)]
        CACHE[(Valkey)]
    end

    subgraph AWS["AWS APIs"]
        CF[CloudFormation]
        EC2API[EC2]
        RDSAPI[RDS]
    end

    YOU -->|SSM Session Manager| DEPLOYHOST
    DEPLOYHOST -->|make deploy-all| CF
    DEPLOYHOST -.->|Future: VPC Peering| ProjectVPC
    CF --> ProjectVPC
```

## Architecture

| Component | Description |
|-----------|-------------|
| **Location** | Default VPC (always exists) |
| **Instance Type** | t4g.micro (ARM, ~$3/month) |
| **OS** | Ubuntu 24.04 LTS |
| **Access** | SSM Session Manager only (no inbound ports) |
| **Public IP** | Dynamic (outbound internet only, no EIP) |
| **IAM Role** | AdministratorAccess via instance role (no access keys) |

### Why Separate from Project VPC?

1. **Survivability**: Project VPC can be destroyed/recreated without affecting the deploy host
2. **Independence**: Deploy host doesn't depend on project infrastructure
3. **Simplicity**: No circular dependencies during initial deployment

### Future: VPC Peering

When EC2 instances are deployed in the project VPC, add VPC peering to enable direct access:

```
Default VPC (10.0.0.0/24) <--peering--> Project VPC (10.200.0.0/16)
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
