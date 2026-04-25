---
name: Architecture Quick Reference
description: Key file paths, stack names, resource relationships, and deployment sequence for fast orientation
type: project
originSessionId: f483de33-7dee-4185-b1a3-72a0ada5c58e
---
# Architecture Quick Reference

## Stack Names (ENV=sandbox)
- `cf-scalable-web-sandbox-vpc`
- `cf-scalable-web-sandbox-iam`
- `cf-scalable-web-sandbox-storage`
- `cf-scalable-web-sandbox-image-builder`
- `cf-scalable-web-sandbox-compute-alb`
- `cf-scalable-web-sandbox-compute-nlb`
- `cf-scalable-web-sandbox-compute-nginx`
- `cf-scalable-web-sandbox-compute-php`
- `cf-scalable-web-sandbox-database` (optional, runtime)
- `cf-scalable-web-sandbox-cache` (optional, runtime)
- `cf-deploy-host` (standalone, no ENV prefix)

## AWS Account
- **Sandbox**: 033879516417 (ZI-Sandbox profile, assumes OrganizationAccountAccessRole)
- **Parent/Management**: 645925380349 (worxco alias, kvanderw user)

## Deploy-All Sequence (~50 min)
1. Foundation: VPC → IAM → Storage (FSx ~15 min)
2. Image Builder: deploy stack → upload configs → trigger 3 AMI builds → poll until AVAILABLE (~25 min)
3. AMI Params: write to SSM (`/sandbox/ami/nginx`, `/sandbox/ami/php74`, `/sandbox/ami/php83`)
4. Compute: ALB → NLB → NGINX → PHP (~5 min)

## Key SSM Parameters
- `/environment/name` → sandbox
- `/${ENV}/fsx/dns-name` → FSx NFS hostname
- `/${ENV}/cache/endpoint` → Valkey hostname
- `/${ENV}/nlb/endpoint` → NLB DNS
- `/${ENV}/ami/nginx`, `/${ENV}/ami/php74`, `/${ENV}/ami/php83` → AMI IDs
- `/${ENV}/rds/endpoint` → RDS hostname (when deployed)

## Key Secrets Manager Paths
- `worxco/${env}/cache/auth-token` → Valkey AUTH
- `worxco/${env}/rds/master-password` → RDS password
- `worxco/deploy-host/github-ssh-key` → Deploy key (private + public)
- `worxco/deploy-host/root-password` → Optional root password

## Boot Script Flow (PHP instances)
1. UserData calls `/opt/worxco/configure-php.sh` (baked into AMI)
2. Script gets IMDS token → region → reads `/environment/name` from SSM
3. Mounts FSx: `mount -t nfs4 -o vers=4.1,port=2049 $FSX_DNS:/fsx /var/www`
4. Configures Valkey session handler from `/${ENV}/cache/endpoint`
5. Configures Postfix SES relay (if SES credentials exist)
6. Starts PHP-FPM and health-check NGINX (port 9100)

## Image Builder Version Bumping
When changing component content in cf-image-builder.yaml:
1. Edit the template
2. Bump `RecipeVersion` in `cloudformation/parameters/image-builder-sandbox.json`
3. `make deploy-image-builder ENV=sandbox`
4. `make upload-build-configs ENV=sandbox`
5. `make build-amis ENV=sandbox`
6. Wait for completion, then `make update-ami-param` for each pipeline
7. `make deploy-compute-nginx` + `make deploy-compute-php` (ForceUpdateToken forces re-resolution)
