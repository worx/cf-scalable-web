# cf-scalable-web - Project Configuration

## Project Overview

This project provides a complete CloudFormation-based infrastructure for scalable Drupal/WordPress hosting on AWS.

**Key Features:**
- Multi-tier VPC architecture (defense in depth)
- NGINX reverse proxies with SSL termination (CertBot DNS-01)
- PHP-FPM pools with port-based routing (1074→PHP 7.4, 1083→8.3, etc.)
- RDS PostgreSQL Multi-AZ, FSx OpenZFS shared storage, ElastiCache Redis
- Auto-scaling with 7-day instance lifecycle (immutable infrastructure)
- EC2 Image Builder for automated AMI creation
- Optional monitoring and compliance features

## Standards

This project follows **The Worx Company** standards as defined in `~/.claude/CLAUDE.md`:

- **GPL-2.0-or-later** licensing on all source files
- **ISO 9001** (Quality) and **ISO 27001** (Security) compliance
- Comprehensive documentation with Mermaid diagrams
- Full test coverage
- Security-first design (input validation, least privilege, audit logging)

## Project-Specific Rules

### CloudFormation Templates

1. **Modular design** - Each stack is independent and can be updated without affecting others
2. **Parameterization** - All environment-specific values are parameters (no hardcoding)
3. **Outputs** - Every stack exports values needed by other stacks
4. **Validation** - All templates must pass `cfn-lint` before commit
5. **Documentation** - Each template has header comments explaining purpose, parameters, and dependencies

### Directory Structure

```
cloudformation/          # CloudFormation templates
  parameters/            # Parameter files per environment
image-builder/           # EC2 Image Builder configurations
  components/            # Reusable build components
  recipes/               # Image recipes
scripts/                 # Deployment and management scripts
docs/                    # Documentation
tests/                   # Test suite
```

### Naming Conventions

**Resources:** `{EnvironmentName}-{Service}-{Component}`
- Example: `production-nginx-asg`, `staging-php74-asg`

**Parameters:** PascalCase
- Example: `EnvironmentName`, `PHPVersions`, `NginxInstanceType`

**Outputs:** PascalCase with service prefix
- Example: `VpcId`, `NginxSecurityGroupId`, `RdsEndpoint`

### Security Guidelines

1. **No public IPs** except ALB
2. **Secrets Manager** for all sensitive values (SSH keys, passwords, API tokens)
3. **IAM least privilege** - each role has minimum required permissions
4. **Security groups** - layered, no 0.0.0.0/0 except on ALB ports 80/443
5. **Encryption at rest** - RDS, FSx, S3, ElastiCache all encrypted
6. **Encryption in transit** - SSL/TLS everywhere

### Deployment Workflow

1. **Validate** templates: `make validate`
2. **Review** parameters: Edit `cloudformation/parameters/{env}.json`
3. **Deploy** foundation: `make deploy-vpc deploy-iam deploy-storage`
4. **Deploy** data layer: `make deploy-database deploy-cache`
5. **Build** AMIs: `make build-amis`
6. **Deploy** compute: `make deploy-nginx deploy-php`
7. **Health check**: `make health-check`

### Before Committing

- [ ] All CloudFormation templates pass `cfn-lint`
- [ ] All scripts have GPL-2.0-or-later headers
- [ ] All functions have purpose/parameters/returns documentation
- [ ] Tests pass (`make test`)
- [ ] Documentation updated
- [ ] Commit message prepared in `.git/COMMIT_MSG_DRAFT`

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
