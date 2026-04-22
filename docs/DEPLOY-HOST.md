# Deploy Host Setup

This document describes the standalone deploy host for managing cf-scalable-web infrastructure deployments.

## Overview

The deploy host is a small EC2 instance that runs in the **default VPC**, separate from the project infrastructure. This design allows:

- Long-running deployments (40+ minutes) without laptop dependency
- Persistent sessions via `tmux` or `screen`
- Survival across project VPC teardowns
- SSM Session Manager access (primary) and SSH (backup)

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

    YOU -->|SSM / SSH| DEPLOYHOST
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
| **Access** | SSM Session Manager (primary) + SSH (backup) |
| **Public IP** | Dynamic (no EIP cost when stopped) |

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
2. **Office/VPN IP**: For SSH security group lockdown
3. **AWS CLI**: Configured on your laptop for initial deploy

## Deployment

### 1. Configure Parameters

Edit `cloudformation/parameters/deploy-host.json`:

```json
{
  "Parameters": {
    "KeyPairName": "",
    "AllowedSSHCidr": "YOUR_OFFICE_IP/32",
    "InstanceType": "t4g.micro"
  }
}
```

| Parameter | Description |
|-----------|-------------|
| `KeyPairName` | Leave empty to create new key pair, or specify existing |
| `AllowedSSHCidr` | Your office/VPN IP with /32 (single IP) or /24 (range) |
| `InstanceType` | t4g.micro is sufficient for deployment tasks |

### 2. Deploy

```bash
make deploy-deploy-host
```

This will:
- Create security group (SSH from your IP only)
- Create IAM role (for SSM and CloudFormation access)
- Create key pair (if not specified) and store in SSM Parameter Store
- Launch EC2 instance with all tools pre-installed

### 3. Get Connection Info

```bash
make verify-deploy-host
```

Outputs include:
- `DeployHostPublicIP`: Public IP address
- `SSHCommand`: Ready-to-use SSH command
- `SSMCommand`: SSM Session Manager command
- `KeyPairParameterPath`: Where to retrieve the private key

### 4. Retrieve SSH Key (First Time Only)

If a new key pair was created:

```bash
# Get the parameter path from verify-deploy-host output
aws ssm get-parameter \
  --name /ec2/keypair/key-XXXXXXXX \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text > ~/.ssh/deploy-host.pem

chmod 600 ~/.ssh/deploy-host.pem
```

### 5. Configure SSH (Optional)

Add to `~/.ssh/config` for convenience:

```
Host deploy-host
    HostName <public-ip>
    User ubuntu
    IdentityFile ~/.ssh/deploy-host.pem
```

Then connect with just: `ssh deploy-host`

## Usage

### SSM Session Manager (Primary - No Key Needed)

```bash
aws ssm start-session --target i-XXXXXXXXX
```

This works even if you lose your SSH key.

### SSH Access (Backup)

```bash
ssh -i ~/.ssh/deploy-host.pem ubuntu@<public-ip>
# Or if configured in ~/.ssh/config:
ssh deploy-host
```

### Long-Running Deployments

```bash
# Connect to deploy host via SSM
aws ssm start-session --target i-XXXXXXXXX

# Start a persistent session
tmux new -s deploy

# Clone repo (first time)
cd ~/projects
git clone https://bitbucket.org/worxco/cf-scalable-web.git
cd cf-scalable-web

# Run deployment
make deploy-all ENV=sandbox

# Detach and go home
# Press: Ctrl-B, then D

# Later, reconnect
aws ssm start-session --target i-XXXXXXXXX
tmux attach -t deploy
```

## Pre-Installed Tools

| Tool | Purpose |
|------|---------|
| `aws` | AWS CLI v2 |
| `git` | Version control |
| `make` | Build automation |
| `tmux` / `screen` | Persistent sessions |
| `vim` | Text editor (set as default) |
| `tree` | Directory visualization |
| `jq` | JSON processing |
| `cfn-lint` | CloudFormation linting |
| `claude` | Claude Code CLI |
| `node` / `npm` | Node.js runtime |

## Security

### SSH Lockdown

- Security group allows SSH only from `AllowedSSHCidr`
- Update security group if your IP changes:

```bash
# Find security group
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=cf-deploy-host-sg" \
  --query 'SecurityGroups[0].GroupId' --output text

# Update SSH rule
aws ec2 authorize-security-group-ingress \
  --group-id sg-XXXXXXXX \
  --protocol tcp --port 22 \
  --cidr NEW_IP/32
```

### SSM Session Manager

- Provides access without SSH key
- All sessions logged to CloudTrail
- Primary access method

### IAM Role

The deploy host has `AdministratorAccess` for infrastructure management. This is intentional — it needs to create/modify all AWS resources including IAM roles and policies.

## Teardown

```bash
make destroy-deploy-host
```

This deletes:
- EC2 instance
- Security group
- IAM role and instance profile
- Key pair (if created by stack)

**Note**: The private key in SSM Parameter Store is NOT deleted. Clean it up manually if needed.

## Troubleshooting

### Can't SSH

1. Check security group allows your current IP
2. Verify key permissions: `chmod 600 ~/.ssh/deploy-host.pem`
3. Use SSM Session Manager as backup

### Instance Not Responding

```bash
# Check instance status
aws ec2 describe-instance-status --instance-ids i-XXXXXXXX

# View console output
aws ec2 get-console-output --instance-id i-XXXXXXXX --output text
```

### Bootstrap Failed

SSH in and check:
```bash
cat /var/log/deploy-host-bootstrap.log
cat /var/log/deploy-host-bootstrap-status
```

## Cost

| Resource | Monthly Cost |
|----------|--------------|
| t4g.micro | ~$6.00 |
| EBS (20GB gp3) | ~$1.60 |
| **Total** | **~$7.60/month** |

Stop the instance when not in use to save on compute costs:

```bash
make stop-deploy-host    # Stop instance
make start-deploy-host   # Start instance
```

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
