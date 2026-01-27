# SPDX-License-Identifier: GPL-2.0-or-later
# Sandbox Testing Guide

This guide covers testing Phase 1 infrastructure in a sandbox AWS account.

## Prerequisites

1. **AWS Sandbox Account**
   - Separate AWS account for testing
   - Configured with AWS CLI credentials
   - Sufficient permissions for CloudFormation, EC2, RDS, ElastiCache, FSx

2. **AWS CLI Configuration**
   ```bash
   # Configure sandbox profile
   aws configure --profile sandbox

   # Set environment
   export AWS_PROFILE=sandbox
   export AWS_REGION=us-east-1
   ```

3. **Cost Considerations**

   Sandbox parameters use minimal resources:
   - VPC: 1 AZ, 1 NAT Gateway (~$33/month)
   - FSx: 64GB, 64 MB/s throughput (~$13/month)
   - RDS: db.t4g.micro, 20GB storage (~$14/month)
   - ElastiCache: cache.t4g.micro, 1 node (~$11/month)

   **Estimated cost: ~$71/month if left running**

   **Recommendation**: Destroy stacks immediately after testing to avoid charges

## Sandbox Parameters

The `cloudformation/parameters/sandbox.json` file contains minimal configuration:

- **Environment**: sandbox (10.200.0.0/16 CIDR)
- **Availability Zones**: 1 (single AZ)
- **NAT Gateway**: Single (no HA)
- **FSx**: 64GB storage, 64 MB/s, 1-day backups
- **RDS**: db.t4g.micro, 20GB, 1-day backups
- **Redis**: cache.t4g.micro, single node
- **No VPC Flow Logs, Performance Insights, or Enhanced Monitoring**

## Testing Strategy

### Sequential Testing (Recommended First)

Test each stack individually to isolate issues:

```bash
# 1. Test VPC stack
./scripts/test-deployment.sh test-vpc

# 2. Verify VPC deployment
./scripts/test-deployment.sh status

# 3. Test IAM stack
./scripts/test-deployment.sh test-iam

# 4. Test Storage stack (FSx + S3)
./scripts/test-deployment.sh test-storage

# 5. Test Database stack (RDS PostgreSQL)
./scripts/test-deployment.sh test-database

# 6. Test Cache stack (ElastiCache Redis)
./scripts/test-deployment.sh test-cache

# 7. Destroy everything
./scripts/test-deployment.sh destroy-all
```

### Full Stack Testing

After sequential testing passes, test all stacks together:

```bash
# Deploy all stacks in order
./scripts/test-deployment.sh test-all

# Verify all stacks
./scripts/test-deployment.sh status

# Destroy all stacks
./scripts/test-deployment.sh destroy-all
```

## Dry-Run Testing

Test the deployment process without creating AWS resources:

```bash
# Dry-run individual stack
./scripts/test-deployment.sh --dry-run test-vpc

# Dry-run full deployment
./scripts/test-deployment.sh --dry-run test-all

# Dry-run destruction
./scripts/test-deployment.sh --dry-run destroy-all
```

## What to Verify

### VPC Stack (cf-vpc.yaml)
- [ ] VPC created with 10.200.0.0/16 CIDR
- [ ] 5 subnets created (public, nginx, nlb, php-fpm, data)
- [ ] Internet Gateway attached
- [ ] NAT Gateway in public subnet
- [ ] Route tables configured correctly
- [ ] 7 Security Groups created with correct rules
- [ ] Exports created for cross-stack references

**CLI Verification:**
```bash
# List VPC resources
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=sandbox-vpc" --region us-east-1

# List subnets
aws ec2 describe-subnets --filters "Name=tag:aws:cloudformation:stack-name,Values=cf-scalable-web-sandbox-vpc" --region us-east-1

# List security groups
aws ec2 describe-security-groups --filters "Name=tag:aws:cloudformation:stack-name,Values=cf-scalable-web-sandbox-vpc" --region us-east-1

# List CloudFormation exports
aws cloudformation list-exports --region us-east-1 | jq '.Exports[] | select(.Name | startswith("sandbox"))'
```

### IAM Stack (cf-iam.yaml)
- [ ] 5 IAM roles created (NGINX, PHP-FPM, 3 Image Builder roles)
- [ ] Instance profiles created
- [ ] Policies attached with least privilege
- [ ] Route 53 permissions for NGINX (CertBot)
- [ ] S3/RDS/Redis permissions for PHP-FPM
- [ ] SSM permissions for Session Manager

**CLI Verification:**
```bash
# List IAM roles
aws iam list-roles --query 'Roles[?contains(RoleName, `sandbox`)]' --region us-east-1

# Check role policies
aws iam list-attached-role-policies --role-name sandbox-nginx-instance-role --region us-east-1
aws iam list-role-policies --role-name sandbox-nginx-instance-role --region us-east-1
```

### Storage Stack (cf-storage.yaml)
- [ ] FSx for OpenZFS filesystem created
- [ ] Deployment time < 2 minutes
- [ ] S3 bucket for media created
- [ ] S3 bucket policy configured
- [ ] Exports created for FSx/S3 references

**CLI Verification:**
```bash
# List FSx filesystems
aws fsx describe-file-systems --region us-east-1 | jq '.FileSystems[] | select(.Tags[] | select(.Key=="aws:cloudformation:stack-name" and (.Value | contains("sandbox"))))'

# Check FSx mount targets
aws fsx describe-file-systems --region us-east-1 | jq '.FileSystems[] | select(.Tags[] | select(.Key=="aws:cloudformation:stack-name" and (.Value | contains("sandbox")))) | .DNSName'

# List S3 buckets
aws s3 ls | grep sandbox
```

**Timing Test:**
```bash
# Time FSx deployment
time ./scripts/test-deployment.sh test-storage
# Should complete in < 2 minutes total (including CloudFormation overhead)
```

### Database Stack (cf-database.yaml)
- [ ] RDS PostgreSQL instance created
- [ ] Single AZ deployment (no Multi-AZ)
- [ ] db.t4g.micro instance class
- [ ] 20GB storage allocated
- [ ] DB subnet group created
- [ ] Master password stored in Secrets Manager
- [ ] Security group allows connections from PHP tier
- [ ] Automated backups configured (1 day retention)

**CLI Verification:**
```bash
# List RDS instances
aws rds describe-db-instances --query 'DBInstances[?TagList[?Key==`aws:cloudformation:stack-name` && contains(Value, `sandbox`)]]' --region us-east-1

# Check DB instance details
aws rds describe-db-instances --db-instance-identifier sandbox-db --region us-east-1 | jq '.DBInstances[0] | {Endpoint, Engine, EngineVersion, DBInstanceClass, AllocatedStorage, MultiAZ}'

# Verify master password in Secrets Manager
aws secretsmanager get-secret-value --secret-id worxco/sandbox/rds/master-password --region us-east-1 | jq -r '.SecretString'
```

**Connection Test (from within VPC):**
```bash
# Get endpoint
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier sandbox-db --region us-east-1 --query 'DBInstances[0].Endpoint.Address' --output text)

# Get password
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id worxco/sandbox/rds/master-password --region us-east-1 --query 'SecretString' --output text)

# Test connection (requires psql client and network access)
psql -h "$DB_ENDPOINT" -U dbadmin -d drupal -c "SELECT version();"
```

### Cache Stack (cf-cache.yaml)
- [ ] ElastiCache Redis cluster created
- [ ] cache.t4g.micro node type
- [ ] Single node (no replication)
- [ ] Redis 7.1 version
- [ ] Encryption at rest enabled
- [ ] Encryption in transit enabled
- [ ] Auth token stored in Secrets Manager
- [ ] Security group allows connections from PHP/NGINX tiers

**CLI Verification:**
```bash
# List ElastiCache clusters
aws elasticache describe-replication-groups --region us-east-1 | jq '.ReplicationGroups[] | select(.ReplicationGroupId | contains("sandbox"))'

# Check cluster details
aws elasticache describe-replication-groups --replication-group-id sandbox-redis --region us-east-1 | jq '.ReplicationGroups[0] | {Status, CacheNodeType, AtRestEncryptionEnabled, TransitEncryptionEnabled}'

# Get Redis endpoint
aws elasticache describe-replication-groups --replication-group-id sandbox-redis --region us-east-1 --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint' --output table

# Verify auth token in Secrets Manager
aws secretsmanager get-secret-value --secret-id worxco/sandbox/redis/auth-token --region us-east-1 | jq -r '.SecretString'
```

**Connection Test (from within VPC):**
```bash
# Get endpoint
REDIS_ENDPOINT=$(aws elasticache describe-replication-groups --replication-group-id sandbox-redis --region us-east-1 --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)
REDIS_PORT=$(aws elasticache describe-replication-groups --replication-group-id sandbox-redis --region us-east-1 --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Port' --output text)

# Get auth token
REDIS_AUTH=$(aws secretsmanager get-secret-value --secret-id worxco/sandbox/redis/auth-token --region us-east-1 --query 'SecretString' --output text)

# Test connection (requires redis-cli and network access)
redis-cli -h "$REDIS_ENDPOINT" -p "$REDIS_PORT" --tls -a "$REDIS_AUTH" PING
```

## Cross-Stack Integration Testing

Verify that stacks reference each other correctly:

```bash
# Check that Storage stack imports VPC exports
aws cloudformation describe-stacks --stack-name cf-scalable-web-sandbox-storage --region us-east-1 | jq '.Stacks[0].Parameters[] | select(.ParameterValue | startswith("arn:aws:cloudformation"))'

# Check that Database stack imports VPC exports
aws cloudformation describe-stacks --stack-name cf-scalable-web-sandbox-database --region us-east-1 | jq '.Stacks[0].Parameters[] | select(.ParameterValue | startswith("arn:aws:cloudformation"))'
```

## Known Issues and Limitations

### FSx for OpenZFS
- **Minimum storage**: 64GB (cannot go smaller)
- **Minimum throughput**: 64 MB/s (cannot go smaller)
- **Single AZ**: SINGLE_AZ_1 deployment type for cost savings

### RDS PostgreSQL
- **Minimum instance**: db.t4g.micro (smallest ARM instance)
- **Minimum storage**: 20GB (PostgreSQL minimum)
- **Single AZ**: No Multi-AZ replication in sandbox

### ElastiCache Redis
- **Minimum node**: cache.t4g.micro (smallest ARM instance)
- **Single node**: No replication in sandbox

### Security Groups
- Security groups are configured for defense-in-depth
- If testing from local machine, you'll need to add temporary rules
- **Do not expose RDS/Redis directly to internet** - use Systems Manager Session Manager

## Troubleshooting

### Stack Creation Fails

1. Check CloudFormation events:
   ```bash
   aws cloudformation describe-stack-events --stack-name cf-scalable-web-sandbox-vpc --region us-east-1 | jq '.StackEvents[] | select(.ResourceStatus | contains("FAILED"))'
   ```

2. Check CloudFormation resources:
   ```bash
   aws cloudformation describe-stack-resources --stack-name cf-scalable-web-sandbox-vpc --region us-east-1
   ```

3. Review CloudFormation template validation:
   ```bash
   make validate
   ```

### Stack Deletion Fails

Common issues:
- **S3 bucket not empty**: Empty bucket before deletion
- **RDS snapshot retention**: Check for manual snapshots
- **FSx backup retention**: Check for manual backups

Manual cleanup:
```bash
# Empty S3 bucket
aws s3 rm s3://cf-scalable-web-sandbox-media --recursive --region us-east-1

# Delete RDS snapshots
aws rds describe-db-snapshots --db-instance-identifier sandbox-db --region us-east-1 | jq -r '.DBSnapshots[].DBSnapshotIdentifier' | xargs -I {} aws rds delete-db-snapshot --db-snapshot-identifier {} --region us-east-1

# Delete FSx backups
aws fsx describe-backups --region us-east-1 | jq -r '.Backups[] | select(.FileSystem.Tags[] | select(.Key=="aws:cloudformation:stack-name" and (.Value | contains("sandbox")))) | .BackupId' | xargs -I {} aws fsx delete-backup --backup-id {} --region us-east-1
```

### Missing Dependencies

If a stack fails due to missing dependencies:
```bash
# Check CloudFormation imports
aws cloudformation describe-stacks --stack-name cf-scalable-web-sandbox-storage --region us-east-1 | jq '.Stacks[0].Parameters'

# List available exports
aws cloudformation list-exports --region us-east-1 | jq '.Exports[] | select(.Name | startswith("sandbox"))'
```

## Cost Management

### Monitor Costs
```bash
# Get current month costs for sandbox resources
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Environment \
  --filter file://<(echo '{"Tags":{"Key":"Environment","Values":["sandbox"]}}') \
  --region us-east-1
```

### Cleanup After Testing
```bash
# IMPORTANT: Destroy all stacks immediately after testing
./scripts/test-deployment.sh destroy-all

# Verify all resources deleted
./scripts/test-deployment.sh status

# Check for orphaned resources
aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=sandbox --region us-east-1
```

## Test Results Documentation

Create a log of test results in `PROMPT_LOGS/`:

```markdown
# Sandbox Test Results - YYYY-MM-DD

## Environment
- AWS Account: [account-id]
- Region: us-east-1
- Tester: Kurt Vanderwater

## Test 1: Sequential Deployment
- VPC: ✓ SUCCESS (Duration: XXs)
- IAM: ✓ SUCCESS (Duration: XXs)
- Storage: ✓ SUCCESS (Duration: XXs, FSx: XXs)
- Database: ✓ SUCCESS (Duration: XXs)
- Cache: ✓ SUCCESS (Duration: XXs)

## Test 2: Full Stack Deployment
- All Stacks: ✓ SUCCESS (Total Duration: XXs)

## Test 3: Stack Destruction
- Reverse Order: ✓ SUCCESS (Total Duration: XXs)

## Issues Found
[List any issues, errors, or unexpected behavior]

## Recommendations
[List any changes needed to templates]
```

## Next Steps

After successful Phase 1 testing:
1. Document any issues found
2. Create bug fixes if needed
3. Update templates based on findings
4. Proceed to Phase 2: Compute Layer (EC2 Image Builder, NGINX, PHP-FPM)

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
