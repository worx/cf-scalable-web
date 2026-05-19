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

- [ ] **deploy-allX phase ordering — FSx layout init must precede compute.**
  2026-05-19 destroy-all → deploy-allX hit two recurring chicken-and-egg bugs:
  (1) nginx instances boot in Phase 4 and try to mount `$FSX:/fsx/nginx`,
  but `/fsx/nginx` doesn't exist on the freshly-created FSx (no one creates
  it). The mount fails, `configure-nginx.sh` bails on `set -e` BEFORE
  writing `/etc/nginx/conf.d/upstream-php.conf`, and nginx serves with
  the catch-all `server _` only. (2) PHP instances boot in Phase 4 BEFORE
  RDS exists (Phase 5). `configure-php.sh` reads `/sandbox/rds/endpoint`
  from SSM, doesn't find it, skips writing the `env[]` block to
  `www.conf`. PHP-FPM starts with zero DRUPAL_* env vars; Drupal 500s
  forever after.

  **Manual fixups today (will recur)**:
    - SSM-mount /fsx/nginx + manually write upstream-php.conf on every nginx box
    - SSM-re-run /opt/worxco/configure-php.sh on every PHP box after data layer is up

  **Proposed fix** (deferred for architectural review per 2026-05-19 conversation):
    - Add `init-fsx-layout` Make target (run on deploy-host via SSM) that
      mkdir's /fsx/nginx/sites-enabled and any other env-level dirs after
      cf-storage completes.
    - Reorder deploy-allX: parallelize Phase 2 (AMI builds, 20-30 min) with
      Phase 5 (data layer) + init-fsx-layout. Phase 4 (compute) only runs
      once Phase 2 AND data layer AND init-fsx-layout are all done.
    - Or: keep current ordering but add an explicit "compute-ready" gate
      after data layer that triggers instance refresh on already-launched
      compute ASGs.

  **Bigger context** (also captured in TODO under "Architectural review"):
    these recurring chicken-and-egg bugs are symptoms of an architecture
    that assumes strict build order without enforcing it. Worth a
    deliberate think before fixing tactically.

- [ ] **Architectural review — build-order assumptions + multi-site future.**
  Captured from 2026-05-19 end-of-day conversation. Two concerns to think
  through deliberately before more code changes:

  (a) **Build-order coupling**: today's bugs surfaced repeatedly that the
  system assumes a clean greenfield order (VPC → FSx → AMIs → compute →
  data → app → install). Whenever that order is violated — recovery,
  partial redeploy, async resource readiness — components bail silently
  or run with wrong config. Kurt's framing: should worker boxes (PHP,
  nginx) carry intelligence to check/create their prerequisites, or
  should the orchestration enforce order? Open question. Claude's
  position: hard deps stay hard, but worker scripts should fail loudly
  on missing prerequisites instead of `set -e`-bailing mid-config.
  Self-discovery is for runtime peers, not boot deps.

  (b) **Multi-site / multi-RDS future**: the current architecture bakes
  1:1 env↔RDS into many places (settings.php's `$_env`, SSM param
  namespacing, secret paths). Three months out, when we want "two RDS
  side-by-side, some sites on each, migration between them" — we're
  not designed for it. Phase E+ in scope. See `docs/plans/multi-tenancy.md`
  (exists, needs review).

  **Next step** (no implementation yet): review `docs/ARCHITECTURE.md`
  + `docs/plans/multi-tenancy.md`, then more conversations on direction.



- [x] **Bake-and-roll PHP/nginx AMIs to RecipeVersion 1.0.10** ✅ 2026-05-18
  - The `start` → `restart` fix in configure-php.sh / configure-nginx.sh
    (commit 3c70041) is now baked into all 3 AMIs and rolled to every
    nginx + PHP box via instance refresh. Fleet AMIs:
    - nginx = ami-0cc21131caf1c4dac
    - php74 = ami-0ff52af1521570516
    - php83 = ami-0cf37c7c2f6c7d843
  - Smoke test post-rollout: `curl ALB/` → HTTP 200.
  - Future auto-scaling events will launch from these fixed AMIs.

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

- [ ] **`destroy-deploy-host` / `deploy-deploy-host` should handle the
  peering dependency automatically with a persistent restore marker.**
  Bit us 2026-05-19: ran `destroy-deploy-host CONFIRMED=yes`, CFN started
  the delete (DELETE_IN_PROGRESS) then canceled it 1 second later
  because `cf-scalable-web-sandbox-deploy-peering` was still importing
  the `cf-deploy-host-sg-id` export. The stack rolled back to
  CREATE_COMPLETE and our `aws cloudformation wait stack-delete-complete`
  spun for 30+ min before we noticed.

  **Design (Kurt 2026-05-19):** stateful symmetric handling.

  **destroy-deploy-host**:
    1. Query `aws cloudformation list-imports --export-name <our exports>`
       to find every peering stack currently importing from cf-deploy-host.
    2. For each (per-env), write SSM marker
       `/worxco/deploy-host/peering-restore-pending/<env>` = "yes" (or a
       timestamp for audit).
    3. Run `make destroy-peering ENV=<env>` for each, in order.
    4. Then `aws cloudformation delete-stack --stack-name cf-deploy-host`.

  **deploy-deploy-host**:
    1. After the stack reaches CREATE_COMPLETE, list SSM params under
       `/worxco/deploy-host/peering-restore-pending/`.
    2. For each, extract `<env>` from the param name, run
       `make deploy-peering ENV=<env>`.
    3. Delete the SSM param on success of each restore.

  **Why per-env, not global**: future multi-env deploys (sandbox +
  staging both peered) need to remember which envs had peering. Path
  hierarchy makes it natural to add/remove individually.

  **Edge cases handled by this design**:
    - Fresh account, only deploy-host → destroy: no importers, no marker
      written, clean destroy. No-op on re-deploy.
    - Full env up, destroy deploy-host: auto-destroys peering,
      marker remembers, re-deploy restores it.
    - User manually destroyed peering before running destroy-deploy-host:
      no importers found, no marker written. Symmetric — user has to
      manually re-deploy peering if they want it.
    - Partial failure mid-restore: marker stays, next deploy-deploy-host
      run picks up where it left off.

  Generalizable: the same pattern applies to any stack whose exports are
  imported elsewhere. cf-vpc has similar exports.

### P2 — Documentation polish

- [ ] **docs/OPERATIONS.md** — runbooks for use-env, restart-php-fpm,
  clear-drupal-cache, AMI rebuild sequence, common failure modes.
  **In progress 2026-05-18: first cut started.**

- [ ] **docs/master.md + `make build-master`** — design captured below.
  See "Future Enhancements" for the full concept.

- [ ] **Admin SSH key registry for scp-over-SSM-proxy.** Add SSM
  Parameter `/worxco/admin/ssh-public-keys` (StringList) + Make targets
  (`admin-ssh-key-add`, `-remove`, `-list`) + cf-deploy-host UserData
  that installs the keys into the ubuntu user's authorized_keys at boot.
  Compute templates intentionally exclude this code path — security by
  exclusion (see `docs/memory/admin-access-policy.md`). Port 22 stays
  closed in all SGs; keys exist solely to enable scp/sftp/rsync via the
  `AWS-StartSSHSession` SSM document. Captured 2026-05-19.

### P3 — Captured for later (no immediate action)

- [ ] Drupal upgrade promotion workflow (already detailed in
  `~/.claude/TODO.md` under `[cf-scalable-drupal] Phase D`).
- [ ] Multi-tenancy refactor (Phase E+, docs/plans/multi-tenancy.md).
- [ ] **Decide how to handle post-`destroy-all` residue.** Inventory and
  design options in `docs/memory/destroy-all-residue.md`. Three options
  on the table: (A) `clean-account` Make target that sweeps per-service
  residue, (B) `destroy-all` vs `destroy-allX` split mirroring deploy,
  (C) burn-and-recreate the AWS account via Organizations. Also
  includes open SSM "new experience" questions (one-time enablement,
  cost of Default Host Management Config, which Node Tools to enable).
  Captured 2026-05-19; not blocking anything.

- [ ] **`build-amis-if-needed`: skip rebuild when recipe hasn't changed.**
  Today's deploy-allX triggered build #3 of recipe 1.0.10 even though
  the recipe content is identical to yesterday's build #2. Image Builder
  pipelines are CFN resources that get recreated on `destroy-all` →
  `deploy-image-builder`, so they have no concept of "latest" and our
  `build-amis` target blindly triggers every time. Design: a new
  `build-amis-if-needed` target that, for each pipeline, reads the
  current AMI ID from SSM (`/<env>/ami/<pipeline>`), describes the AMI
  to get its Image Builder tag (recipe ARN + version), and compares
  against the recipe currently configured in the pipeline. If they
  match, skip — print "✓ <pipeline> AMI 1.0.10/2 is current". If not,
  trigger + wait as today. Saves ~15-20 min on incremental deploys.
  Make `build-amis-if-needed` the default in deploy-all; keep
  `build-amis` as the force-rebuild variant. Captured 2026-05-19.



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
