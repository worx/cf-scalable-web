---
name: SSL/TLS Certificate Management
description: How ACM provisions, validates, renews, and rotates the HTTPS certs that terminate at the ALB. Pairs with docs/DNS-SETUP.md.
audience: operator
---

# SSL/TLS Certificate Management

This doc covers the cert side of HTTPS: where certs come from, how they
validate, how they renew, what to do when something goes wrong. The DNS
side (sub-zone delegation, A-record publishing) is in
[docs/DNS-SETUP.md](DNS-SETUP.md).

For the strategic question of "why ACM-on-ALB rather than self-managed
nginx + Let's Encrypt," see
[docs/memory/tls-cert-strategy-by-scale.md](memory/tls-cert-strategy-by-scale.md).

## TL;DR

- The cert is created by `cf-compute-alb` as part of `make deploy-allX`
  (Phase 3, compute). No separate cert command to run.
- ACM issues the cert from Amazon Trust Services (publicly-trusted CA);
  validation is DNS-01 against the env's sub-zone; takes 3-5 min.
- AWS auto-renews every ~11 months for as long as the cert is referenced
  by the ALB listener. **Zero operator action required for renewal.**
- Private key never touches the OS — it lives in ACM's HSM-backed
  storage and cannot be exported.
- `make destroy-all` destroys the cert with the stack. No orphans.

## What the stack creates

```
sandbox.envs.zoning-info.com
        │
        │ resolves to
        ▼
ALB (port 443) ────► ACM cert
        │                │
        │ DNS-01         │ validation CNAME
        │ validation     │ at _xxxxxxx.sandbox.envs.zoning-info.com
        ▼                ▼
   envs.zoning-info.com (Route 53 sub-zone in workload account)
```

CloudFormation resource: `AlbCertificate` in `cf-compute-alb.yaml`,
type `AWS::CertificateManager::Certificate`. Created with `ValidationMethod: DNS`
and `DomainValidationOptions.HostedZoneId` pointing at the env's sub-zone.

## Per-env configuration

Each env's `cloudformation/parameters/compute-alb-<env>.json` carries:

| Parameter      | Example value                       | Purpose                                                       |
|----------------|-------------------------------------|---------------------------------------------------------------|
| `DomainName`   | `sandbox.envs.zoning-info.com`      | The FQDN the env serves on. Cert is issued for this name.     |
| `EnvsSubZoneId`| `Z03149452QE09GQX23F48`             | Route 53 zone where ACM writes the validation CNAME.          |

**Both empty → HTTP-only fallback.** A freshly-cloned env with empty
values builds an ALB without TLS — useful for initial bring-up before
DNS delegation exists. Add the values, redeploy compute-alb, and HTTPS
comes up on the next stack update.

**`EnvsSubZoneId` lookup:**

```bash
aws --profile ZI-Sandbox route53 list-hosted-zones \
  --query "HostedZones[?Name=='envs.zoning-info.com.'].Id | [0]" \
  --output text | sed 's|/hostedzone/||'
```

This same value is also used by `publish-dns` (per
[docs/DNS-SETUP.md](DNS-SETUP.md)) — copy it into the compute-alb param
file once at env-setup time and you're done.

## Deployment lifecycle

### First deploy (fresh env)

1. `make deploy-allX ENV=<env>` reaches Phase 3 (compute).
2. `cf-compute-alb` creates the ALB and the cert resource.
3. ACM writes the validation CNAME into the sub-zone within ~30s.
4. ACM polls the resolver, sees its own CNAME, issues the cert (ISSUED status).
5. CFN creates the HTTPS listener using the now-issued cert.
6. Stack creation completes. Total cert wait: usually 3-5 min, sometimes up to 15 min.

If the stack gets stuck waiting for the cert, see "Validation didn't complete" below.

### Renewal (every ~11 months)

ACM monitors the cert's expiry. About 60 days before expiry, ACM
automatically:
1. Issues a new cert (DNS-01 validates against the same sub-zone — the
   validation CNAME from the original issuance is still there).
2. Quietly swaps the cert ARN on the ALB listener.
3. The cert resource's ARN does NOT change; only the underlying X.509
   cert + key rotate.

You don't see this. Nothing breaks. ACM emails the AWS account owner
if anything goes wrong, but in 10 years of running this pattern across
many AWS shops, the failure mode is exceptional.

### Manual rotation (e.g., suspected key compromise)

ACM doesn't expose the private key, so "rotation" in the usual sense
doesn't apply — there's no key on your filesystem to leak. If you want
to force a fresh cert:

1. Edit `cf-compute-alb.yaml`: rename `AlbCertificate` to
   `AlbCertificateV2` (or any new logical ID).
2. `make deploy-compute-alb ENV=<env>`.
3. CFN creates a new cert, swaps the listener over, deletes the old cert.

### Destroy

`make destroy-all ENV=<env>` removes the listener first, then the cert
(ACM disallows deleting a cert that's in use). No cleanup required.

## Drupal-side configuration (HTTPS-aware)

When the ALB terminates TLS, Drupal sees the request as HTTP coming from
the ALB. Without telling Drupal "you're behind a TLS-terminating proxy,"
it will generate `http://` URLs in form actions, asset references, and
canonical links — breaking mixed content under HTTPS access.

`scripts/deploy-host/install-drupal.sh` writes these lines into
`settings.php`:

```php
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = ['10.0.0.0/8'];
```

The CIDR is permissive (the entire RFC1918 10/8 range) but appropriate
here — the ALB is the only thing forwarding to nginx, and nginx-to-PHP
is also intra-VPC, so anything inside the VPC is implicitly trusted.
Tightening this is optional; for production, narrowing to the actual
VPC CIDR (`10.200.0.0/16` for sandbox) is cleaner.

What this enables:
- Drupal reads `X-Forwarded-Proto: https` from the request headers
- Drupal generates `https://` URLs in `$base_url`, form actions, etc.
- `\Drupal::request()->isSecure()` returns true in module code

## Troubleshooting

### Cert validation didn't complete (stack stuck)

`deploy-compute-alb` will sit in `CREATE_IN_PROGRESS` until the cert
hits ISSUED. If it's been more than 15 min, check:

```bash
aws --profile ZI-Sandbox acm list-certificates --query 'CertificateSummaryList[?DomainName==`<env>.envs.zoning-info.com`]'
aws --profile ZI-Sandbox acm describe-certificate --certificate-arn <ARN> \
  --query 'Certificate.DomainValidationOptions'
```

Possible causes:
- **Validation CNAME not in zone**: rare — ACM writes it automatically
  when `HostedZoneId` is in `DomainValidationOptions`. If missing, check
  IAM perms on the deploying role for `route53:ChangeResourceRecordSets`.
- **Wrong `EnvsSubZoneId`**: ACM tried to write to a zone that doesn't
  match the cert's domain. Check the param file.
- **Parent zone delegation broken**: the sub-zone's NS records in the
  parent zone don't match the sub-zone's actual NS servers. Re-run the
  delegation procedure in [DNS-SETUP.md](DNS-SETUP.md).

### Browser shows "NET::ERR_CERT_AUTHORITY_INVALID"

You're hitting the ALB on a hostname OTHER than the cert's DomainName,
and getting the wrong cert back. Check:
```bash
echo | openssl s_client -connect <env>.envs.zoning-info.com:443 \
  -servername <env>.envs.zoning-info.com 2>/dev/null | openssl x509 -noout -subject -issuer
```
Subject should be `CN=<env>.envs.zoning-info.com`. If it's something
else, you're probably hitting the ALB on its `amazonaws.com` name
(which has no cert).

### Smoke test fails: HTTP 400

Drupal rejected the Host header. Usually means `DRUPAL_SITE_NAME` env
var hasn't reached the running PHP-FPM workers yet. Trigger an ASG
instance refresh on the PHP-FPM ASGs — see DNS-SETUP.md for the
command.

### Smoke test fails: SSL handshake error

Cert may be ISSUED but the listener didn't pick it up. Re-run
`make deploy-compute-alb ENV=<env>`. If the stack is in a healthy
state, this is a no-op; if there was a transient issue, the
update reconciles it.

## Cost

- ACM public cert: **$0**, indefinite.
- ALB: ~$16/mo flat + LCU charges (unchanged from HTTP-only — TLS
  termination doesn't change LCU pricing meaningfully at this scale).
- Route 53 hosted zone: $0.50/mo for the parent + $0.50/mo for the
  envs sub-zone — about a dollar a month for any number of envs under it.

Total marginal cost of HTTPS via ACM-on-ALB: **~$0** above the existing
HTTP-only ALB.

## What ACM does NOT do

- **Cannot serve certs to non-AWS targets.** ACM certs can attach to
  ALB / NLB-with-TLS / CloudFront / API Gateway / etc. They cannot be
  exported and used by nginx-on-EC2, by a server outside AWS, by a
  third-party CDN, or by anything that needs to hold the private key.
  See `docs/memory/tls-cert-strategy-by-scale.md` for when this matters.
- **Cannot issue certs for non-public domains.** ACM public certs require
  the domain to be publicly resolvable (because of DNS-01 validation).
  For internal-only certs, use ACM Private CA (separate service, different
  pricing — not in scope here).
- **Cannot issue Extended Validation (EV) certs.** ACM only issues DV
  (Domain Validation) certs. If a customer demands an EV cert for the
  green-bar look in their browser, ACM isn't the right tool.

## Cross-reference

- HTTP→HTTPS redirect mechanics: cf-compute-alb.yaml's `HTTPListener` —
  port 80 returns a 301 to https:// of the same path.
- Drupal-side reverse-proxy trust: install-drupal.sh's settings.php
  template (`$settings['reverse_proxy']`).
- Smoke test over real HTTPS: `make smoke-test-public ENV=<env>`.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
