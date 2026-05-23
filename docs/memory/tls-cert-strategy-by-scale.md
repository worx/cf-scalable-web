---
name: TLS cert strategy by scale (ACM-on-ALB ladder)
description: When ACM-on-ALB is the right answer and when it stops being. Decision ladder for "hundreds of tenants" multi-site futures.
type: reference
created: 2026-05-23
---

# TLS Cert Strategy by Scale

Captured 2026-05-23 during the Phase 3 HTTPS design conversation. The
question came up: "ACM is great for Zoning Info — but what happens when
The Worx Company is hosting hundreds of customer sites on this same
architecture?" Decision: stick with ACM-on-ALB through the multi-ALB
range, with a clearly-marked off-ramp to nginx-on-EC2 + ACME-client only
when the numbers say it's needed.

## Why ACM-on-ALB is the default

ACM (AWS Certificate Manager) issues certs from Amazon Trust Services
(rooted in browsers' trust stores). Free when attached to AWS-managed
TLS terminators (ALB, NLB-with-TLS, CloudFront, API Gateway, etc.).

**Operational properties that matter:**
- **13-month validity, auto-renewed by AWS at ~60 days before expiry.**
  No CertBot daemon, no cron, no renewal-failed-and-cert-expired outage
  at 2am.
- **Private key never leaves ACM's HSM-backed storage.** Cannot be read
  from any filesystem; cannot be exported; cannot accidentally leak into
  a git commit or a backup tarball.
- **DNS-01 validation auto-handled** when the validation zone is in the
  same AWS account as the cert (our pattern with the envs sub-zone
  delegated to ZI-Sandbox).

**Hard constraint to remember:** ACM certs **cannot be deployed to
nginx-on-EC2.** The cert lives in ACM; AWS-managed services can use it
via the cert ARN; the actual cert + key file never touches the OS. If
TLS termination ever moves off ALB and onto nginx, ACM is useless for
that path.

## The cert-per-ALB limit (the real one)

| Limit | Default | Raisable to | Mechanism |
|-------|---------|-------------|-----------|
| Certs per ALB | 25 | ~100 routine, 200-300 with justification, 500+ case-by-case | AWS Service Quotas request |
| ALBs per region | 50 | Higher by ticket | Service Quotas |
| ACM certs per region | 2,500 | Higher by ticket | Service Quotas |

The "25 hard limit" myth comes from the published default. The number is
just a soft default — quota raises are routinely approved, and the
practical engineering ceiling per ALB is several hundred certs before
performance considerations bite.

## Decision ladder

| Tenant count | Recommended pattern | Notes |
|--------------|---------------------|-------|
| 1-25 | Single ALB, ACM, no quota raise | Zero operational effort. Zoning Info lives here. |
| 25-100 | Single ALB, ACM, quota raise to 100 | Routine quota request. Still zero ongoing effort. |
| 100-500 | Single ALB, ACM, quota raise with justification | "We're a SaaS hosting platform" justification typically approved. |
| 500-1500 | Multiple ALBs, ACM on each | Each ALB at 300-500 certs; spread tenants. ~3-5 ALBs total. ~$50-80/mo in ALB fees. |
| 1500-10,000 | Multiple ALBs, ACM, customer-domain → ALB sharding strategy | Now you need a sharding scheme (alphabetical, hash, customer-ID range) and DNS routing logic. Still ACM, but operational complexity rises. |
| 10,000+ | Time to evaluate nginx-on-EC2 + ACME | The marginal cost of ACME automation vs. another N ALBs starts favoring self-management. Re-decide based on engineering cost of automation vs. cost of more ALBs. |

The lower three rows are "the answer is obviously ACM." The middle rows
are "the answer is still ACM with more ALBs." Only at extreme scale
does the trade-off flip.

## Cost framing (~2026 prices)

- **ALB:** $16/mo flat per ALB + per-LCU charges (~$0.008/hour scaled by
  traffic). At 500 tenants/ALB, ALB cost is $0.03/tenant/month — noise.
- **ACM cert:** $0 (public certs attached to AWS services).
- **Engineer time managing renewal infra (Let's Encrypt path):**
  - Initial build: ~40-80 hours one-time
  - Ongoing: ~10-30 hours/year on monitoring, edge cases, rate-limit hits,
    customer support when renewal fails
  - At $100/hr loaded cost, that's $1k-3k/year of recurring cost — buys
    ~60-200 ALBs of headroom.

The break-even cross-over where DIY cert management saves money is
genuinely at the 10k+ tenant scale, AND requires accepting the
operational risk of renewal failures (which ACM has none of).

## When to revisit this memo

Signals that we've outgrown ACM-on-ALB:
- Tenant count crosses 5,000 and showing no signs of plateauing
- Customer demand for a feature ACM can't provide (e.g., EV certs,
  customer-supplied certs, certs from a specific non-AWS CA)
- Architectural shift moves TLS termination off the ALB (e.g., we
  introduce a custom L7 router built on nginx/Envoy)
- An ALB cert quota request gets denied for reasons we can't argue past
  — and we can prove that's a permanent block, not a "submit again with
  different justification" situation

## Fallback architecture sketch (for when ACM truly stops working)

Not implementing this now. Captured so future-us doesn't reinvent it
from scratch when the time comes.

**Pattern: NLB → nginx-on-EC2 → per-domain certs managed by ACME client**

- NLB does TCP passthrough on 443 (no TLS termination at NLB).
- nginx-on-EC2 instances terminate TLS with their own cert store
  (`/etc/nginx/ssl/<domain>/{fullchain.pem,privkey.pem}`).
- An ACME client (`lego`, `dehydrated`, `acme.sh`, or `certbot`) runs
  as a sidecar on each nginx host (or as a central cert-controller with
  certs synced via FSx/S3).
- Renewal automation: ACME client renews on a timer, writes new cert to
  disk, signals nginx `-s reload`.
- Per-instance cert count is RAM-bounded, not API-bounded. A single
  nginx instance can hold tens of thousands of certs.

**What this costs (above current architecture):**
- Engineering time to build the cert-controller
- Engineering time to monitor it (failed renewals, LE rate limits,
  customer cert provisioning edge cases)
- A different blast radius — a cert-controller bug can break renewal
  for many domains at once (vs. ACM, where each renewal is independent
  and AWS-managed)

**Reference clients to evaluate when the time comes:**
- `lego` (Go, single binary, ALPN/DNS-01/HTTP-01 challenges, ~recently maintained)
- `dehydrated` (bash, used by Cloudflare among others, very stable)
- `acme.sh` (the "everyone has used this at some point" option)
- `certbot` (Python, official Let's Encrypt client, heavy)

## Cross-reference

- Current ALB+ACM design: `cf-compute-alb.yaml` (Phase 3 / v0.2.0-https milestone)
- Multi-tenancy roadmap: `docs/plans/multi-tenancy.md`
- DNS sub-zone delegation (prereq for ACM DNS-01 validation): `docs/DNS-SETUP.md`
