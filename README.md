# cf-scalable-web

Scalable AWS infrastructure for Drupal and WordPress hosting using CloudFormation.

## Overview

This project provides a complete, production-ready infrastructure for hosting multiple Drupal and WordPress sites with high availability, auto-scaling, and defense-in-depth security.

### Key Features

- **Multi-tier VPC architecture** with defense-in-depth security
- **NGINX reverse proxies** with SSL termination (Let's Encrypt via DNS-01)
- **Port-based PHP-FPM routing** (9074→PHP 7.4, 9083→8.3, etc.)
- **RDS PostgreSQL Multi-AZ** for database
- **FSx for OpenZFS** shared storage (not EFS - proven faster for Drupal)
- **ElastiCache Valkey** for page caching
- **Auto-scaling** with 7-day instance lifecycle (immutable infrastructure)
- **EC2 Image Builder** for automated AMI creation
- **Modular CloudFormation templates** for independent stack updates
- **Optional monitoring and compliance** features

### Architecture Highlights

```
Internet → ALB → NGINX (SSL) → NLB (port routing) → PHP-FPM → RDS PostgreSQL
                   ↓                                     ↓
              ElastiCache Valkey                   FSx OpenZFS
```

- **No public IPs** except on ALB (defense in depth)
- **Layered security groups** preventing lateral movement
- **Weekly instance refresh** for immutable infrastructure
- **Secrets Manager** for all credentials (no hardcoded passwords)

## Quick Start

### Prerequisites

- AWS CLI configured with credentials
- `cfn-lint` for template validation
- `jq` for JSON processing
- `make` for simplified commands

```bash
# Install prerequisites (macOS)
brew install awscli cfn-lint jq

# Configure AWS CLI
aws configure
```

### Initial Setup

1. **Clone and explore:**
   ```bash
   cd cf-scalable-web
   make help
   ```

2. **Initialize secrets:**
   ```bash
   make init-secrets ENV=production
   # Follow prompts to set root password, SSH keys, notification email
   ```

3. **Customize parameters:**
   ```bash
   # Edit parameter file for your environment
   nano cloudformation/parameters/production.json
   ```

4. **Validate templates:**
   ```bash
   make validate
   ```

5. **Deploy all stacks (~50 min):**
   ```bash
   make deploy-all ENV=production
   ```

   This runs a 4-phase lifecycle:

   | Phase | What | Approx. Time |
   |-------|------|--------------|
   | 1. Foundation | VPC, IAM, Storage (FSx OpenZFS, S3) | ~20 min |
   | 2. Image Builder + AMI Builds | Deploy Image Builder, upload configs, trigger 3 parallel AMI builds (NGINX, PHP 7.4, PHP 8.3), wait for completion | ~25 min |
   | 3. AMI Parameters | Write AMI IDs to SSM (`/ENV/ami/nginx`, `/ENV/ami/php74`, `/ENV/ami/php83`) | ~1 min |
   | 4. Compute | ALB, NLB, NGINX ASG, PHP-FPM ASGs | ~5 min |

   **Database and Cache are optional runtime dependencies** (not included in
   `deploy-all`). Deploy them separately when needed:
   ```bash
   make deploy-database ENV=production  # RDS PostgreSQL Multi-AZ (~10 min, ~$75/mo)
   make deploy-cache ENV=production     # ElastiCache Valkey (~12 min, ~$12/mo)
   ```

   Or deploy compute stacks individually:
   ```bash
   make deploy-compute-alb ENV=production    # Application Load Balancer
   make deploy-compute-nlb ENV=production    # Network Load Balancer (port routing)
   make deploy-compute-nginx ENV=production  # NGINX Auto Scaling Group
   make deploy-compute-php ENV=production    # PHP-FPM Auto Scaling Groups
   ```

## Project Structure

```
cf-scalable-web/
├── cloudformation/              # CloudFormation templates
│   ├── cf-vpc.yaml             # VPC infrastructure
│   ├── cf-iam.yaml             # IAM roles and policies
│   ├── cf-storage.yaml         # FSx and S3
│   ├── cf-database.yaml        # RDS PostgreSQL
│   ├── cf-cache.yaml           # ElastiCache Valkey
│   ├── cf-compute-alb.yaml     # Application Load Balancer
│   ├── cf-compute-nlb.yaml     # Network Load Balancer (port routing)
│   ├── cf-compute-nginx.yaml   # NGINX Auto Scaling Group
│   ├── cf-compute-php.yaml     # PHP-FPM Auto Scaling Groups
│   ├── cf-deploy-host.yaml     # Deploy host (standalone, default VPC)
│   └── parameters/             # Environment-specific parameters
│       ├── production.json     # Production foundation values
│       ├── staging.json        # Staging foundation values
│       ├── sandbox.json        # Sandbox foundation values
│       ├── deploy-host.json    # Deploy host parameters
│       ├── compute-alb-*.json  # ALB parameters per environment
│       ├── compute-nlb-*.json  # NLB parameters per environment
│       ├── compute-nginx-*.json # NGINX parameters per environment
│       └── compute-php-*.json  # PHP-FPM parameters per environment
├── image-builder/               # EC2 Image Builder configurations
│   ├── components/             # Reusable build components
│   └── recipes/                # Image recipes
├── scripts/                     # Management scripts
│   └── manage-secrets.sh       # Secrets Manager operations
├── docs/                        # Documentation
│   ├── ARCHITECTURE.md         # Architecture details with diagrams
│   ├── DEPLOY-HOST.md          # Deploy host setup and usage
│   ├── SANDBOX-TESTING.md      # Sandbox testing guide
│   └── SECRETS.md              # Secrets management architecture
├── tests/                       # Test suite
│   └── test-templates.sh       # CloudFormation template tests
├── Makefile                     # Deployment automation
└── README.md                   # This file
```

## Common Operations

### Deploy a specific stack

```bash
make deploy-vpc ENV=production
make deploy-database ENV=production
make deploy-compute-alb ENV=production
make deploy-compute ENV=production       # All compute stacks in order
```

### Verify deployments

```bash
make verify-vpc ENV=production
make verify-compute-alb ENV=production
make verify-compute ENV=production       # Verify all compute stacks
```

### Update an existing stack

Edit parameters, then re-run deploy:
```bash
nano cloudformation/parameters/production.json
make deploy-storage ENV=production
```

### Manage secrets

```bash
# List secrets
make list-secrets ENV=production

# Add SSH key
./scripts/manage-secrets.sh add-ssh-key alice ~/.ssh/id_rsa.pub worxco/production

# Get a secret value
./scripts/manage-secrets.sh get ssh-keys/kurt worxco/production
```

### Delete stacks

```bash
# Delete in reverse order
make destroy-compute ENV=staging  # PHP → NGINX → NLB → ALB
make destroy-cache ENV=staging
make destroy-database ENV=staging  # WARNING: Data loss!
make destroy-storage ENV=staging   # WARNING: Data loss!
make destroy-iam ENV=staging
make destroy-vpc ENV=staging
```

## Environments

### Production
- **VPC CIDR:** 10.101.0.0/16
- **Multi-AZ:** Yes
- **NAT Gateway HA:** Yes
- **Backups:** 14 days
- **Monitoring:** Optional (set `EnableCompliance: true`)

### Staging
- **VPC CIDR:** 10.102.0.0/16
- **Multi-AZ:** Yes (cost-optimized)
- **NAT Gateway HA:** No (single NAT Gateway)
- **Backups:** 7 days
- **Monitoring:** Disabled

### Development
Create `cloudformation/parameters/dev.json` with minimal resources.

## Cost Optimization

**Estimated monthly costs (production):**
- VPC (NAT Gateways): ~$65/mo (2 AZs)
- RDS PostgreSQL (db.t4g.small Multi-AZ): ~$75/mo
- FSx OpenZFS (100GB, 128MB/s): ~$50/mo
- ElastiCache Valkey (cache.t4g.micro): ~$12/mo
- **Total base infrastructure: ~$202/mo**

Compute costs (NGINX, PHP-FPM) depend on traffic and scaling.

**Cost-saving tips:**
- Use `staging` environment for testing (50% cheaper)
- Disable Multi-AZ in dev/test
- Single NAT Gateway instead of HA
- Smaller instance types for low-traffic sites

## Security

- **Defense in depth:** 4-tier private subnets, no lateral movement
- **Secrets Manager:** All passwords, keys, tokens
- **Encryption:** At rest (RDS, FSx, S3) and in transit (Valkey, SSL)
- **IAM least privilege:** Each role has minimum required permissions
- **VPC Flow Logs:** Optional (set `EnableVPCFlowLogs: true`)
- **Session Manager:** Audited SSH access via SSM (deploy host for long-running operations)

## Documentation

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Detailed architecture with Mermaid diagrams
- **[DEPLOY-HOST.md](docs/DEPLOY-HOST.md)** - Deploy host setup and SSM access
- **[DEPLOYMENT.md](docs/DEPLOYMENT.md)** - Step-by-step deployment guide *(coming soon)*
- **[OPERATIONS.md](docs/OPERATIONS.md)** - Day-2 operations *(coming soon)*
- **[SSL-MANAGEMENT.md](docs/SSL-MANAGEMENT.md)** - CertBot DNS-01 setup *(coming soon)*

## Roadmap

### Phase 1: Foundation (Complete)
- [x] VPC, IAM, Storage, Database, Cache stacks
- [x] Secrets management script
- [x] Makefile for deployment
- [x] Parameter templates
- [x] Basic documentation

### Phase 2: Compute Layer (Complete)
- [x] EC2 Image Builder pipelines (NGINX, PHP-FPM)
- [x] PHP version component management
- [x] Application Load Balancer (HTTP→HTTPS redirect)
- [x] Network Load Balancer (port-based routing: 9074→PHP 7.4, 9083→PHP 8.3)
- [x] NGINX Auto Scaling Group (CPU + request-count scaling, 7-day lifecycle)
- [x] PHP-FPM Auto Scaling Groups (per-version conditional ASGs, flow-count scaling)
- [x] SSM Parameter integration (/environment/name, /nlb/endpoint)
- [x] Makefile deploy/verify/destroy targets for all compute stacks

### Phase 3: SSL & Routing
- [ ] CertBot DNS-01 integration
- [ ] Let's Encrypt automation
- [ ] Health check scripts
- [ ] End-to-end testing

### Phase 4: Monitoring & Compliance
- [ ] CloudWatch dashboards
- [ ] Alarms and SNS notifications
- [ ] CloudTrail, VPC Flow Logs
- [ ] Compliance documentation (ISO 27001)

### Phase 5: Advanced Features
- [ ] Blue/green and canary deployment support
- [ ] LaTeX PDF service (Lambda + Docker)
- [ ] Multi-region support
- [ ] Cost estimation tool

## Support

For issues, questions, or contributions, contact:

**Kurt Vanderwater**
Email: kurt@worxco.net
Company: The Worx Company

## License

This project is licensed under GPL-2.0-or-later.

```
SPDX-License-Identifier: GPL-2.0-or-later
Copyright (C) 2026 The Worx Company
Author: Kurt Vanderwater <kurt@worxco.net>
```

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
