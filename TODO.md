# cf-scalable-web TODO

## Phase 1: Core Infrastructure ✅ COMPLETE

- [x] Create project structure (.claude/, cloudformation/, scripts/, docs/, tests/)
- [x] Write cf-vpc.yaml (VPC, subnets, security groups)
- [x] Write cf-iam.yaml (IAM roles and policies)
- [x] Write cf-storage.yaml (FSx OpenZFS, S3 buckets)
- [x] Write cf-database.yaml (RDS PostgreSQL)
- [x] Write cf-cache.yaml (ElastiCache Redis)
- [x] Write scripts/manage-secrets.sh (add/browse/change/delete secrets)
- [x] Write Makefile (deploy-all, deploy-vpc, validate, etc.)
- [x] Create parameters/production.json template
- [x] Write docs/ARCHITECTURE.md with Mermaid diagrams
- [x] Write README.md
- [x] Write LICENSE

## Phase 2: Compute Layer (NEXT)

- [ ] Write image-builder/php-components.yaml (PHP 7.2, 7.4, 8.1, 8.3 package lists)
- [ ] Write cf-image-builder.yaml (NGINX pipeline, PHP-FPM pipelines)
- [ ] Write Image Builder components:
  - [ ] base-hardening.yaml
  - [ ] install-nginx.yaml (+ certbot + Route 53 DNS plugin)
  - [ ] install-php-fpm.yaml (parameterized by version)
  - [ ] configure-monitoring.yaml (CloudWatch agent)
- [ ] Write cf-compute-nginx.yaml (ALB TCP mode, NGINX ASG, 7-day lifecycle)
- [ ] Write cf-compute-php.yaml (NLB, dynamic port mapping, PHP ASGs per version)
- [ ] Test: Build AMIs, launch instances, verify FSx mounting

## Phase 3: SSL & Routing

- [ ] Configure CertBot DNS-01 on NGINX instances
- [ ] Decide: Route 53 zone list in SSM Parameter vs. wildcard permission
- [ ] Test: Request cert for test domain, verify renewal
- [ ] Write docs/SSL-MANAGEMENT.md
- [ ] Write scripts/health-check.sh (test ALB, NLB ports, RDS, FSx, Redis)
- [ ] Test: End-to-end request flow (Browser → ALB → NGINX → NLB → PHP-FPM → RDS)

## Phase 4: Auto Scaling & Lifecycle

- [ ] Configure Auto Scaling target tracking (75% threshold, 180s/600s cooldown)
- [ ] Set maximum instance lifetime = 7 days
- [ ] Test: Load spike simulation, verify scale-out
- [ ] Test: Wait 7 days (or manually trigger), verify instance replacement
- [ ] Write scripts/add-php-version.sh
- [ ] Test: Add PHP 8.4, verify new ASG + NLB listener

## Phase 5: Monitoring & Compliance (Optional)

- [ ] Write cf-monitoring.yaml (dashboards, alarms, SNS topics, log groups)
- [ ] Write cf-compliance.yaml (CloudTrail, VPC Flow Logs, AWS Config rules)
- [ ] Test: Trigger alarm, verify SNS notification
- [ ] Write docs/OPERATIONS.md
- [ ] Write docs/TROUBLESHOOTING.md
- [ ] Write docs/COMPLIANCE.md (ISO 27001 controls mapping)

## Phase 6: Testing & Documentation

- [ ] Write tests/test-vpc.sh (verify subnets, NAT, security groups)
- [ ] Write tests/test-php-routing.sh (NLB port routing verification)
- [ ] Write tests/test-ssl-renewal.sh (mock CertBot dry-run)
- [ ] Run full test suite
- [ ] Write docs/DEPLOYMENT.md (step-by-step deployment guide)
- [ ] Final review: All GPL-2.0-or-later headers present
- [ ] Final review: All CloudFormation parameters documented
- [ ] Create example deployment recording (optional)

## Future Enhancements (Phase 2+)

- [ ] LaTeX PDF service (Lambda + Docker, SQS queue, S3 output)
- [ ] Cost estimation tool
- [ ] Backup verification script
- [ ] Blue/green deployment automation
- [ ] Multi-region support

## Open Questions

- [ ] Route 53 zone permission strategy: SSM Parameter list vs. wildcard?
- [ ] Lambda for AMI auto-update, or manual SSM Parameter change?
- [ ] Multi-AZ for FSx (production only, or always)?

---

**Project:** cf-scalable-web
**Contact:** Kurt Vanderwater <<kurt@worxco.net>>
**Started:** 2026-01-26
**Phase 1 Completed:** 2026-01-26
**Status:** Ready for Phase 2 (Compute Layer)

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
