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
  - Sequence on deploy-host: `make deploy-image-builder` → `make build-ami-php74 / php83 / nginx` → wait ~15 min → `make update-ami-param` (x3) → `make deploy-compute` → instance refresh.

- [ ] **Fix install-drupal.sh psql heredoc password mangling**
  - The CREATE USER heredoc is bash-double-quoted, so any `$` or backtick in
    the password gets shell-expanded before reaching psql. cf-app-drupal's
    tightened ExcludeCharacters (commit a8fba8d) prevents NEW passwords from
    having those chars, but the bug is still latent — change a single character
    in the exclusion set and it bites again.
  - Fix: use `psql -c "ALTER USER … WITH PASSWORD '$pw';"` via a here-string
    OR a single-quoted heredoc, OR pipe the password via stdin with `\password`.

- [ ] **Deploy-host cutover to `/var/www` mount**
  - The use-env / single-mount commits (ee16258, ee319d5) are in git but the
    running deploy-host still has FSx mounted at `/var/www/sandbox`. Steps in
    that commit's message: pull, re-run bootstrap.sh, unmount `/var/www/sandbox`,
    strip its fstab entry, run `sudo use-env sandbox`, verify, then
    `make deploy-app-drupal` to update the SSM install-path parameter.

### P1 — Operational improvements (close the traps that bit us)

- [ ] **`make check-drift`** — for each `cloudformation/cf-*.yaml`, compare
  local mtime to the deployed stack's LastUpdatedTime; warn when local is
  newer (means edits sit in git but haven't been deployed). The cf-iam
  drift sat undeployed for 6 days, causing the "empty DB password" trap.

- [ ] **`make build-amis` should wait for pipelines to reach AVAILABLE.**
  Right now it kicks off and returns immediately; chained `update-ami-param`
  finds the previous (old) AVAILABLE AMI and writes that to SSM. We hit
  this twice. Add a polling step at the end.

- [ ] **`make update-ami-params`** (plural wrapper) — calls
  `update-ami-param` for nginx/php74/php83. The current per-pipeline API is
  easy to forget; I also accidentally invented a `deploy-ami-params` name
  that didn't exist and watched it silently fail.

- [ ] **`make restart-php-fpm ENV=<env>`** — SSM-exec fleet-wide restart.
  Needed any time settings.php changes on FSx (OPcache otherwise serves
  stale code) or any time env vars in www.conf change without an instance
  cycle.

- [ ] **`make clear-drupal-cache ENV=<env>`** — wipe both layers:
  `rm /var/www/drupal/web/sites/default/files/php/*` on FSx AND TRUNCATE
  the cache_* tables in PostgreSQL. The DB-cached compiled service
  container was what blocked us from resolving the app_root mismatch.

- [ ] **OPcache reset story.** Either: configure-php.sh writes a hook that
  invalidates OPcache on settings.php mtime change, OR document loudly
  that "edit settings.php → `make restart-php-fpm`" is mandatory.

### P2 — Documentation polish

- [ ] **docs/OPERATIONS.md** — runbooks for use-env, restart-php-fpm,
  clear-drupal-cache, AMI rebuild sequence, common failure modes.

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
