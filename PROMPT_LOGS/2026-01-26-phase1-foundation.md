# Prompt Log: Phase 1 Foundation Infrastructure

**Date:** 2026-01-26
**Project:** cf-scalable-web
**Author:** Kurt Vanderwater
**Session:** Initial project setup and Phase 1 implementation

---

## Session Summary

### Objective
Build the foundation infrastructure for a scalable Drupal/WordPress hosting platform on AWS using CloudFormation.

### Scope
Phase 1: Core Infrastructure (VPC, IAM, Storage, Database, Cache)

---

## Planning Phase

### Initial Requirements Gathered

**Infrastructure Services:**
- Application Load Balancer (ALB) - front-end, TCP passthrough mode
- NGINX servers (2+) - reverse proxy, SSL termination, multi-AZ
- ElastiCache Redis - page caching
- Network Load Balancer (NLB) - port-based PHP routing (1074→PHP 7.4, 1083→8.3)
- PHP-FPM pools - multiple versions (7.2, 7.4, 8.1, 8.3)
- RDS PostgreSQL Multi-AZ - database
- FSx for OpenZFS - shared storage (NOT EFS - proven 90s deployment vs 20+ min)
- S3 - media uploads, backups

**Architecture Decisions:**
- Multi-tier VPC (4 private subnet layers + public for ALB)
- Defense-in-depth security (no lateral movement between tiers)
- Port-based PHP routing: 10XX = PHP X.X (1074→7.4, 1083→8.3)
- Weekly instance replacement (7-day lifecycle, immutable infrastructure)
- Auto-scaling at 75% capacity (~8-10 threads per t4g.small PHP instance)
- SSL termination at NGINX (not ALB) to support unlimited domains
- CertBot DNS-01 via Route 53 (works with private NGINX instances)
- Secrets Manager for all credentials (no hardcoded passwords/keys)
- Systems Manager Session Manager (no bastion host)

**Deployment Strategy:**
- Modular CloudFormation templates (independent stack updates)
- Parameterized for multiple environments (production, staging, dev)
- Optional monitoring/compliance features (toggleable)

**Region:** us-east-1
**Project Name:** cf-scalable-web (generic, not Drupal-specific)

---

## Implementation Phase

### CloudFormation Templates Created

1. **cf-vpc.yaml** (1,100+ lines)
   - VPC with configurable CIDR (default: 10.101.0.0/16)
   - 4-tier private subnet architecture + public tier
   - Public subnets: 10.101.1-3.0/24 (ALB only)
   - Private tier 1: 10.101.11-13.0/24 (NGINX)
   - Private tier 2: 10.101.21-23.0/24 (NLB)
   - Private tier 3: 10.101.31-33.0/24 (PHP-FPM)
   - Private tier 4: 10.101.41-43.0/24 (RDS, FSx, ElastiCache)
   - NAT Gateways with HA option (1 or 2+ based on AZ count)
   - 7 security groups (ALB, NGINX, NLB, PHP-FPM, RDS, FSx, ElastiCache)
   - Optional VPC Flow Logs (for compliance)
   - Supports 1-3 Availability Zones

2. **cf-iam.yaml** (400+ lines)
   - NGINX instance role (Session Manager, Secrets, Route 53 for CertBot, CloudWatch, FSx)
   - PHP-FPM instance role (Secrets, S3, CloudWatch, FSx, RDS/Redis credentials)
   - Image Builder instance role (SSM Parameter Store for AMI IDs)
   - Image Builder service role (EC2 operations)
   - Auto Scaling lifecycle role

3. **cf-storage.yaml** (300+ lines)
   - FSx for OpenZFS (100GB default, 128MB/s throughput, ZSTD compression)
   - Supports SINGLE_AZ_1 (dev/test) and MULTI_AZ_1 (production)
   - Daily automated backups (14-day retention)
   - S3 buckets: media, backups, image-builder
   - Lifecycle policies (Glacier transition, version cleanup)
   - SSM Parameters for FSx DNS, S3 bucket names

4. **cf-database.yaml** (350+ lines)
   - RDS PostgreSQL Multi-AZ (db.t4g.small default)
   - PostgreSQL 16.1 (configurable: 16.1, 15.5, 14.10)
   - Custom parameter group optimized for Drupal
   - 100GB storage with auto-scaling to 1TB
   - Master password in Secrets Manager (auto-generated)
   - 14-day automated backups
   - Optional Performance Insights and Enhanced Monitoring
   - DeletionProtection enabled

5. **cf-cache.yaml** (250+ lines)
   - ElastiCache Redis 7.1 (cache.t4g.micro default)
   - Encryption in transit + at rest
   - Auth token in Secrets Manager
   - Optional Multi-AZ with automatic failover
   - No backups (cache is ephemeral)
   - Custom parameter group (allkeys-lru eviction policy)

**All templates validated with cfn-lint successfully.**

### Management Scripts

**scripts/manage-secrets.sh** (300+ lines)
- Actions: add-ssh-key, add-secret, get, list, delete, init
- Interactive initialization wizard
- Color-coded output
- Dependency checks (aws-cli, jq)
- AWS credential validation
- Safety confirmations for deletions

### Deployment Automation

**Makefile** (200+ lines)
- Comprehensive deployment targets
- `make validate` - cfn-lint + jq parameter validation
- `make deploy-all` - Deploy all stacks in order
- `make deploy-vpc/iam/storage/database/cache` - Individual deployments
- `make delete-*` - Stack cleanup with safety confirmations
- `make init-secrets` - Initialize Secrets Manager
- `make list-secrets` - List all secrets
- `make test` - Run test suite
- Environment support: ENV=production|staging|dev
- Color-coded output

### Configuration Files

**cloudformation/parameters/**
- `template.json` - Parameter documentation
- `production.json` - Production config (10.101.0.0/16, Multi-AZ, HA NAT)
- `staging.json` - Staging config (10.102.0.0/16, cost-optimized)

### Documentation

**README.md** (400+ lines)
- Project overview
- Quick start guide
- Common operations
- Environment configurations
- Cost estimates (~$202/mo base infrastructure)
- Security overview
- Project structure
- Roadmap (Phases 1-5)

**docs/ARCHITECTURE.md** (1,200+ lines)
- 10+ Mermaid diagrams
- Network architecture (VPC layout, security groups)
- Request flow (HTTP/HTTPS, caching strategy)
- PHP version port mapping
- Auto-scaling architecture
- Instance lifecycle (7-day replacement)
- Storage architecture (FSx, S3)
- Database architecture (RDS Multi-AZ)
- SSL certificate management (CertBot DNS-01)
- IAM roles and permissions
- Monitoring and observability
- High availability design
- Failure scenarios and recovery
- Performance optimization
- Security best practices

**TODO.md**
- Phase tracking (1-6)
- Task breakdown per phase
- Open questions
- Future enhancements

**LICENSE**
- GPL-2.0-or-later

**Project Configuration**
- `.claude/CLAUDE.md` - Project-specific instructions
- `.claude/settings.json` - Project metadata
- `.gitignore` - Git exclusions (including PROMPT_LOGS/)

---

## Testing & Validation

### Validation Performed
- All 5 CloudFormation templates: `cfn-lint` passed ✅
- Parameter files: `jq empty` validation passed ✅
- Scripts: `shellcheck` pending (Phase 2)
- Makefile: Syntax validated ✅

### Tests Written
- None yet (deferred to Phase 6)
- Test stubs created: tests/test-vpc.sh, tests/test-templates.sh (pending)

---

## Decisions Made

### Key Design Decisions

1. **SSL Strategy:** NGINX handles SSL termination (not ALB)
   - **Rationale:** Unlimited domains via SNI (ALB limit: 25 certs/listener)
   - **Method:** CertBot DNS-01 via Route 53 (no ALB routing issues)

2. **Admin Access:** Systems Manager Session Manager (no bastion host)
   - **Rationale:** No cost, audited sessions, browser-based access

3. **PHP Version Management:** Dynamic via php-components.yaml
   - **Rationale:** Easy to add new versions without template changes

4. **AMI Updates:** Image Builder → SSM Parameter → Auto Scaling
   - **Rationale:** Automated weekly builds, instances auto-refresh every 7 days

5. **Database:** RDS PostgreSQL (not MariaDB/MySQL)
   - **Rationale:** Drupal compatibility, better for future workloads

6. **Shared Storage:** FSx for OpenZFS (NOT EFS)
   - **Rationale:** EFS deployment: 20+ min timeout, FSx: <90s (proven in production)

7. **Deployment Strategy:** Canary (default), Blue/Green (optional)
   - **Rationale:** Safe testing, gradual rollout

8. **Monitoring/Compliance:** Optional (parameter toggles)
   - **Rationale:** Cost control for dev/test environments

### Open Questions Documented

1. **Route 53 zone permissions:**
   - Option A: SSM Parameter list of allowed zones (dynamic, secure)
   - Option B: Wildcard permission (simpler, less secure)
   - **Decision deferred:** Will implement Option A in Phase 3

2. **AMI auto-update:**
   - Option A: Lambda updates launch template when Image Builder finishes
   - Option B: Manual SSM Parameter change
   - **Decision:** Maximum automation for weekly builds, manual for new PHP versions

3. **FSx Multi-AZ:**
   - Production: Optional (cost consideration)
   - **Decision:** Parameter-driven, default SINGLE_AZ_1

---

## Deliverables

### Files Created (14 total)

**CloudFormation Templates (5):**
- cloudformation/cf-vpc.yaml
- cloudformation/cf-iam.yaml
- cloudformation/cf-storage.yaml
- cloudformation/cf-database.yaml
- cloudformation/cf-cache.yaml

**Parameters (3):**
- cloudformation/parameters/template.json
- cloudformation/parameters/production.json
- cloudformation/parameters/staging.json

**Scripts (1):**
- scripts/manage-secrets.sh (executable)

**Documentation (3):**
- README.md
- docs/ARCHITECTURE.md
- TODO.md

**Project Files (2):**
- Makefile
- LICENSE

**Configuration:**
- .claude/CLAUDE.md
- .claude/settings.json
- .gitignore

**Directories Created:**
- cloudformation/parameters/
- image-builder/components/
- image-builder/recipes/
- scripts/
- docs/
- tests/
- PROMPT_LOGS/

---

## Statistics

- **5 CloudFormation templates** - ~3,500 lines of YAML
- **1 management script** - ~300 lines of Bash
- **1 Makefile** - ~200 lines
- **Documentation** - ~1,600 lines of Markdown
- **10+ Mermaid diagrams** - Architecture visualization
- **All templates validated** - cfn-lint passed

---

## Next Steps (Phase 2)

### Immediate Actions Needed

1. **Git Repository:**
   - Create initial commit
   - Push to GitHub (new repository: worxco/cf-scalable-web)

2. **Testing:**
   - Write tests/test-vpc.sh (subnet validation)
   - Write tests/test-templates.sh (cfn-lint + parameter checks)
   - Add dry-run option to manage-secrets.sh

3. **Deploy & Verify:**
   - Run `make init-secrets ENV=production`
   - Deploy foundation: `make deploy-all ENV=production`
   - Verify stacks created successfully

### Phase 2 Scope

**EC2 Image Builder:**
- image-builder/php-components.yaml (package lists per PHP version)
- cf-image-builder.yaml (NGINX + PHP-FPM pipelines)
- Image Builder components (base-hardening, install-nginx, install-php-fpm, configure-monitoring)

**Compute Layer:**
- cf-compute-nginx.yaml (ALB TCP mode, NGINX ASG, 7-day lifecycle)
- cf-compute-php.yaml (NLB port-based routing, PHP ASGs per version)

**Testing:**
- Build AMIs via Image Builder
- Launch instances, verify FSx mounting
- Test NLB port routing (1074→PHP 7.4, 1083→8.3)

---

## Issues & Resolutions

### Issue: Database Parameter Group Family String
**Problem:** PostgreSQL version parameter needs to match parameter group family format
**Resolution:** Used `!Sub 'postgres${PostgreSQLVersion}'` for dynamic family name

### Issue: cfn-lint Warning on DeletionPolicy
**Problem:** RDS instance had `DeletionPolicy: Snapshot` but missing `UpdateReplacePolicy`
**Resolution:** Added `UpdateReplacePolicy: Snapshot` to cf-database.yaml:204

### Issue: FSx Subnet Selection for Multi-AZ
**Problem:** Multi-AZ deployment requires specific subnet configuration
**Resolution:** Used conditional `!If [MultiAZDeployment, ...]` to select all subnets vs. first subnet only

---

## Compliance Notes (ISO 27001)

### Security Controls Implemented

- **Access Control (A.9):**
  - IAM least privilege roles
  - Systems Manager Session Manager (audited access)
  - No SSH keys in user-data (Secrets Manager)

- **Cryptography (A.10):**
  - RDS encryption at rest (KMS)
  - FSx encryption at rest
  - S3 encryption (SSE-S3)
  - Redis encryption in transit
  - SSL/TLS for all connections

- **Network Security (A.13):**
  - Defense-in-depth subnet architecture
  - Security groups with least privilege
  - No public IPs except ALB
  - Optional VPC Flow Logs

- **Audit Logging (A.12):**
  - CloudWatch Logs (optional)
  - VPC Flow Logs (optional)
  - CloudTrail (Phase 5)
  - Session Manager logging (Phase 5)

### Optional Compliance Features (Disabled by Default)

- `EnableCompliance: false` (default)
- When enabled: CloudWatch agent, VPC Flow Logs, enhanced monitoring
- Phase 5: CloudTrail, AWS Config, compliance documentation

---

## Lessons Learned

1. **Modular templates are essential** - Independent stack updates prevent cascading failures
2. **Parameters > hardcoding** - Every environment-specific value should be a parameter
3. **cfn-lint catches issues early** - Validates resources, properties, intrinsic functions
4. **SSM Parameter Store for non-sensitive config** - FSx DNS, AMI IDs, etc.
5. **Secrets Manager for sensitive data** - Passwords, tokens, SSH keys
6. **Defense in depth works** - Multi-tier subnets prevent lateral movement
7. **FSx > EFS for Drupal** - Proven 90s deployment vs 20+ min timeout
8. **Documentation is critical** - Mermaid diagrams make architecture clear

---

## Session Conclusion

**Phase 1: Core Infrastructure** - ✅ COMPLETE

**Status:** Ready for Phase 2 (Compute Layer)

**Next Session:** Implement EC2 Image Builder pipelines and compute layer (NGINX, PHP-FPM, ALB, NLB)

---

**Prompt Log:** PROMPT_LOGS/2026-01-26-phase1-foundation.md
**Author:** Kurt Vanderwater <<kurt@worxco.net>>
**Company:** The Worx Company
**License:** GPL-2.0-or-later

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
