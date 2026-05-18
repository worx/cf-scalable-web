# cf-scalable-web TODO

## Phase 1: Core Infrastructure ✅ COMPLETE

- [x] Create project structure (.claude/, cloudformation/, scripts/, docs/, tests/)
- [x] Write cf-vpc.yaml (VPC, subnets, security groups)
- [x] Write cf-iam.yaml (IAM roles and policies)
- [x] Write cf-storage.yaml (FSx OpenZFS, S3 buckets)
- [x] Write cf-database.yaml (RDS PostgreSQL)
- [x] Write cf-cache.yaml (ElastiCache Valkey)
- [x] Write scripts/manage-secrets.sh (add/browse/change/delete secrets)
- [x] Write Makefile (deploy-all, deploy-vpc, validate, etc.)
- [x] Create parameters/production.json template
- [x] Write docs/ARCHITECTURE.md with Mermaid diagrams
- [x] Write README.md
- [x] Write LICENSE

## Phase 2: Compute Layer ✅ COMPLETE

- [x] Write cf-image-builder.yaml (NGINX pipeline, PHP-FPM 7.4/8.3 pipelines)
- [x] Write Image Builder components (base-hardening, install-nginx, install-php-fpm, test components)
- [x] Write cf-compute-alb.yaml (Application Load Balancer)
- [x] Write cf-compute-nlb.yaml (Network Load Balancer, port-based routing)
- [x] Write cf-compute-nginx.yaml (NGINX ASG, 7-day lifecycle)
- [x] Write cf-compute-php.yaml (PHP-FPM ASGs per version)
- [x] Write cf-deploy-host.yaml (standalone deploy host, SSM-only, auto-clones repo)
- [x] Full deploy-all lifecycle: VPC → IAM → Storage → Image Builder → AMI builds → compute
- [x] VPC endpoints for private subnet AWS API access (SSM, Secrets Manager, S3)
- [x] Test: Build AMIs, launch instances, all healthy (2026-04-24)

## Operational Hardening — Lessons from 2026-05-13 → 2026-05-18

A multi-day debug arc surfaced many real issues that have been fixed in
flight (and committed) but left operational gaps worth closing. Items are
prioritized by "would this bite again if we don't fix it."

### P0 — Regressions waiting to happen (do soonest)

- [ ] **Bake-and-roll PHP/nginx AMIs to RecipeVersion 1.0.10** (commit 3c70041)
  - The `start` → `restart` fix in configure-php.sh / configure-nginx.sh is in
    git + S3 but NOT in any deployed AMI. Live boxes have been manually
    restarted — they work. Any new instance cycle (auto-scaling, instance
    refresh, ASG replacement) launches from old AMIs and re-breaks Drupal
    (empty env vars in workers → HTTP 400 "host name not valid").
  - Sequence: `make deploy-image-builder` → `make build-amis` (now waits) →
    `make update-ami-params` → `make deploy-compute` → instance refresh.
  - **In progress 2026-05-18: AMI bake running, deploy-image-builder done,
    instance refresh still to do.**

- [x] **Fix install-drupal.sh psql heredoc password mangling** ✅ commit a52e38a
  - On investigation the heredoc was NOT actually vulnerable (bash variable
    substitution is single-pass), but the modernized `psql -v` + `:'var'`
    form is cleaner and the operational-ordering comment (install-drupal.sh
    must be re-run after cf-app-drupal deploys) captures the actual root
    cause of the 5-15 password mismatch.

- [ ] **Deploy-host cutover to `/var/www` mount**
  - The use-env / single-mount commits (ee16258, ee319d5) are in git but the
    running deploy-host still has FSx mounted at `/var/www/sandbox`. Steps in
    that commit's message: pull, re-run bootstrap.sh, unmount `/var/www/sandbox`,
    strip its fstab entry, run `sudo use-env sandbox`, verify, then
    `make deploy-app-drupal` to update the SSM install-path parameter.

- [ ] **Deploy cf-app-drupal** (`make check-drift` surfaced this 2026-05-18)
  - `cf-app-drupal.yaml` has committed-but-undeployed changes from 5-15
    (the install-path SSM update). `make deploy-app-drupal ENV=sandbox`.
  - Roll into the deploy-host cutover above since both touch the same area.

### P1 — Operational improvements (close the traps that bit us)

- [x] **`make check-drift`** — for each `cloudformation/cf-*.yaml`, compare
  local mtime to the deployed stack's LastUpdatedTime; warn when local is
  newer (means edits sit in git but haven't been deployed). ✅ commit d3ca66f.
  Caught a real drift (cf-app-drupal) on first run.

- [x] **`make build-amis` waits for pipelines to reach AVAILABLE.** ✅ commit
  d47a0d4. Split into `build-amis-async` (old fire-and-forget behavior, opt-in)
  and `build-amis` (= async + new `wait-amis` waiter).

- [x] **`make update-ami-params`** (plural) ✅ commit d47a0d4. Also includes
  `deploy-ami-params` as an alias for muscle memory.

- [x] **`make restart-php-fpm ENV=<env>`** ✅ commit c813613.

- [x] **`make clear-drupal-cache ENV=<env>`** ✅ commit c813613. Operates via
  SSM through the deploy-host; refuses to run if active env doesn't match
  the requested env.

- [x] **OPcache reset story.** ✅ Resolved as "documented" rather than coded:
  `make restart-php-fpm` is the canonical answer when settings.php on FSx
  changes. Will be noted prominently in docs/OPERATIONS.md.

### P2 — Documentation polish

- [ ] **docs/OPERATIONS.md** — runbooks for use-env, restart-php-fpm,
  clear-drupal-cache, AMI rebuild sequence, common failure modes.
  **In progress 2026-05-18: first cut started.**

- [ ] **docs/master.md + `make build-master`** — design captured below.
  See "Future Enhancements" for the full concept.

### P3 — Captured for later (no immediate action)

- [ ] Drupal upgrade promotion workflow (already detailed in
  `~/.claude/TODO.md` under `[cf-scalable-drupal] Phase D`).
- [ ] Multi-tenancy refactor (Phase E+, docs/plans/multi-tenancy.md).



- [ ] Configure CertBot DNS-01 on NGINX instances
- [ ] Decide: Route 53 zone list in SSM Parameter vs. wildcard permission
- [ ] Test: Request cert for test domain, verify renewal
- [ ] Write docs/SSL-MANAGEMENT.md
- [ ] Write scripts/health-check.sh (test ALB, NLB ports, RDS, FSx, cache)
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

### Design captured 2026-05-18: Master PDF documentation aggregation

  Idea (Kurt): the project's *.md files are scattered across the root,
  `docs/`, and other places. For onboarding and overview reading, ship a
  single hyperlinked **master.pdf** that aggregates them all into a
  book-shaped document.

  - **Source of truth**: `docs/master.md` — a manifest file that lists
    each *.md to include and in what order. Effectively the book's
    table of contents + author's note.

  - **Suggested ordering**:
    1. Getting Started / Introduction (README content, project pitch)
    2. Detailed Make target documentation — every `make <target>`
       documented for end-users, NOT just the one-line help text in
       the Makefile. May require new doc generation from the Makefile.
    3. Architecture (docs/ARCHITECTURE.md)
    4. Operations / Deploy-host (docs/DEPLOY-HOST.md, OPERATIONS.md)
    5. Reference (SECRETS.md, GITHUB-SETUP.md, etc.)

  - **Build tooling**: use the existing LaTeX skill / `latex` plugin to
    produce the PDF. Hyperlinks via `hyperref`, TOC + index via LaTeX
    standard machinery.

  - **Make target**: `make build-master` — first check that LaTeX is
    installed locally (`command -v pdflatex` or `latexmk`). If missing,
    print a clear instruction message (Mac: `brew install
    --cask mactex-no-gui` or similar). NOT runnable on the deploy-host
    (which intentionally lacks LaTeX).

  - **Git posture**: master.pdf and intermediate LaTeX artifacts
    (`*.aux`, `*.log`, `*.toc`, `*.out`, `*.tex` if generated) all in
    `.gitignore`. Always rebuilt fresh from current sources; never
    committed.

  - **Update cadence**: source `*.md` files are updated continuously as
    code changes. master.pdf is regenerated on demand — typically when
    someone wants a full system overview, not on every commit.

  - **Open questions to resolve at build time**:
    - LaTeX skill or pandoc → LaTeX → pdflatex? Pandoc handles
      Markdown → LaTeX conversion more cleanly than ad-hoc.
    - How to document Make targets — parse Makefile help comments, or
      write a separate `docs/make-targets.md` that's hand-maintained?
    - Single concatenated PDF or sectioned with explicit page breaks?

## Open Questions

- [ ] Route 53 zone permission strategy: SSM Parameter list vs. wildcard?
- [ ] Lambda for AMI auto-update, or manual SSM Parameter change?
- [ ] Multi-AZ for FSx (production only, or always)?

---

**Project:** cf-scalable-web
**Contact:** Kurt Vanderwater <<kurt@worxco.net>>
**Started:** 2026-01-26
**Phase 1 Completed:** 2026-01-26
**Phase 2 Completed:** 2026-04-24 (compute fleet)
**Phase C (Drupal install) Completed:** 2026-05-15 (Drupal serving end-to-end)
**Status:** Operational hardening (post-debug-arc cleanup); SSL/Routing (Phase 3) deferred

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
