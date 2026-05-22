# DNS Setup — Sub-zone Delegation for Env URLs

Operator runbook for giving each environment a human-friendly URL (e.g.
`sandbox.envs.zoning-info.com`) instead of the raw ALB DNS name.

This is **not** automated by the CloudFormation stacks because:
- The parent zone lives in a different AWS account from the workloads
- Different deployments of this project will use entirely different domains
- The one-time setup steps are operator decisions, not stack inputs

What CFN/Makefile **does** automate (once the delegation is in place):
- Reading the ALB DNS + canonical hosted zone ID
- Creating/deleting the alias record in the env's sub-zone
- Pushing `DRUPAL_SITE_NAME` into the env so Drupal trusts the new Host header

## Project context (specific to this deployment)

| Item | Value |
|------|-------|
| Parent domain | `zoning-info.com` |
| Parent hosted zone ID | `Z1NMHTNRCOHJAQ` |
| Parent account | (org parent — separate from workload account) |
| Parent-account profile | `zikvanderw` |
| Workload account | `033879516417` (ZI-Sandbox) |
| Workload-account profile | `ZI-Sandbox` |
| Region (workload) | `us-east-1` |
| Env sub-zone (recommended) | `envs.zoning-info.com` |

The recommended pattern (described below) needs **one** delegation in the
parent zone — after that, every env (`sandbox`, `test-new`, etc.) becomes a
record inside the `envs.zoning-info.com` sub-zone, managed entirely from the
workload account.

## Two patterns documented

| Pattern | Resulting URLs | Parent-account touches |
|---------|----------------|------------------------|
| **A. Envs sub-zone** (recommended) | `sandbox.envs.zoning-info.com`<br>`test-new.envs.zoning-info.com`<br>`prod.envs.zoning-info.com` | **1, ever** |
| B. Per-env sub-zones | `sandbox.zoning-info.com`<br>`test-new.zoning-info.com` | 1 per env |

Pattern A wins for ongoing operations: the parent zone is touched exactly
once, then never again. All future env adds, ALB rotations, destroy/redeploy
cycles, etc. happen entirely in the workload account.

Pattern B is documented for completeness — if you need an env to live
directly under the apex (e.g. for cookie-domain reasons, or because the URL
is going on a business card), this is how.

---

## Pattern A — One-time setup: delegate `envs.zoning-info.com` (recommended)

### Step 1 — Create the sub-zone in the workload account

Run as the workload-account operator:

```bash
aws --profile ZI-Sandbox route53 create-hosted-zone \
  --name envs.zoning-info.com \
  --caller-reference "envs-zone-$(date +%s)" \
  --hosted-zone-config Comment="Workload sub-zone — managed by cf-scalable-drupal"
```

Record the new zone ID from the output (looks like `Z01234567ABCDEFGHIJK`).
Save it; you'll reference it from the env-publishing commands below.

Then list the four NS records AWS auto-assigned to the new zone:

```bash
aws --profile ZI-Sandbox route53 get-hosted-zone --id <new-sub-zone-id> \
  --query 'DelegationSet.NameServers' --output text
```

You'll get something like:
```
ns-123.awsdns-12.com  ns-456.awsdns-34.net  ns-789.awsdns-56.org  ns-1234.awsdns-78.co.uk
```

### Step 2 — Create the NS delegation record in the parent zone

Run as the parent-account operator:

```bash
cat > /tmp/envs-delegation.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "envs.zoning-info.com.",
      "Type": "NS",
      "TTL": 172800,
      "ResourceRecords": [
        {"Value": "ns-123.awsdns-12.com."},
        {"Value": "ns-456.awsdns-34.net."},
        {"Value": "ns-789.awsdns-56.org."},
        {"Value": "ns-1234.awsdns-78.co.uk."}
      ]
    }
  }]
}
EOF
aws --profile zikvanderw route53 change-resource-record-sets \
  --hosted-zone-id Z1NMHTNRCOHJAQ \
  --change-batch file:///tmp/envs-delegation.json
```

Replace the four `Value` lines with the NS names from Step 1's output.

### Step 3 — Verify

After ~60 seconds (parent zone TTL is fast):

```bash
dig +short NS envs.zoning-info.com
```

Should return the four `ns-*.awsdns-*` hostnames. If it returns nothing, wait
another minute (DNS propagation), or check the change-batch ran clean:

```bash
aws --profile zikvanderw route53 list-resource-record-sets \
  --hosted-zone-id Z1NMHTNRCOHJAQ \
  --query "ResourceRecordSets[?Name=='envs.zoning-info.com.']"
```

**Done.** From here, all per-env operations stay inside ZI-Sandbox.

---

## Pattern A — Publishing an env to DNS

This is the per-env runbook. Run after `make deploy-allX ENV=<env>` succeeds
and the ALB is healthy.

> ⚠️ **Two different hosted zone IDs are about to show up — don't mix them up.**
>
> An ALB alias record references **two** Route 53 hosted zone IDs that play
> very different roles:
>
> | Variable | What it is | Where it goes |
> |----------|-----------|---------------|
> | `$ENVS_ZONE_ID` | The Route 53 zone **you own** (the `envs.zoning-info.com` sub-zone created in the one-time setup) | `--hosted-zone-id` argument to `change-resource-record-sets` |
> | `$ALB_ZONE` | AWS's **regional ALB constant** (`Z35SXDOTRQ7X7K` for us-east-1) — same value for every ALB in the region | Inside the change-batch JSON, as `AliasTarget.HostedZoneId` |
>
> If you put the ALB constant where `$ENVS_ZONE_ID` belongs, Route 53 will
> return a misleading **AccessDenied** error — because you're effectively
> trying to write into an AWS-owned zone that no customer can modify.
> Symptom: `User: ... is not authorized to access this resource`. The
> account permissions are fine; the zone ID is wrong.

### Get the envs sub-zone ID

In a fresh shell, look it up rather than typing it from memory:

```bash
ENVS_ZONE_ID=$(aws --profile ZI-Sandbox route53 list-hosted-zones \
  --query "HostedZones[?Name=='envs.zoning-info.com.'].Id | [0]" --output text \
  | sed 's|/hostedzone/||')
echo "envs sub-zone: $ENVS_ZONE_ID"
```

(The `sed` strips the `/hostedzone/` prefix that Route 53 returns; the CLI
accepts both forms, but commands look cleaner without the prefix.)

### Get the ALB's DNS name and canonical hosted zone ID

The ALB is published as a CFN export. Both values are needed for the alias
record:

```bash
ENV=sandbox
ALB_DNS=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
  --stack-name "cf-scalable-web-$ENV-compute-alb" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" --output text)
ALB_ZONE=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
  --stack-name "cf-scalable-web-$ENV-compute-alb" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBHostedZoneId'].OutputValue" --output text)
echo "ALB: $ALB_DNS  zone: $ALB_ZONE"
```

`$ALB_ZONE` will print `Z35SXDOTRQ7X7K` (for us-east-1). That's the value
that goes into `AliasTarget.HostedZoneId` in the JSON below — **not** into
`--hosted-zone-id`.

### Create the alias record

```bash
# $ENVS_ZONE_ID, $ENV, $ALB_DNS, $ALB_ZONE all defined above.

cat > /tmp/env-alias.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$ENV.envs.zoning-info.com.",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "$ALB_DNS",
        "HostedZoneId": "$ALB_ZONE",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
EOF
aws --profile ZI-Sandbox route53 change-resource-record-sets \
  --hosted-zone-id "$ENVS_ZONE_ID" \
  --change-batch file:///tmp/env-alias.json
```

Verify:
```bash
dig +short "$ENV.envs.zoning-info.com"
```

Should return the ALB's resolved IPs (typically 2 — one per AZ).

### Tell Drupal to accept the new Host header

Drupal's `trusted_host_patterns` (in the env-driven settings.php) reads
`DRUPAL_SITE_NAME` from the environment. The PHP-FPM boot script
(`image-builder/configs/configure-php.sh`) reads `/<env>/drupal/site-name`
from SSM at instance boot and injects it into the FPM pool config — so
the source of truth is the SSM parameter.

**Push the SSM parameter:**

```bash
aws --profile ZI-Sandbox ssm put-parameter \
  --name "/$ENV/drupal/site-name" \
  --type String \
  --value "$ENV.envs.zoning-info.com" \
  --overwrite
```

This is what `make install-drupal` reads too (via the deploy-host's
`ssm_or` helper), so future reinstalls will use the new value as well.

**Make running PHP-FPM workers see it (without an AMI rebuild):**

The injection happens at instance boot, so the running workers still have
the old `DRUPAL_SITE_NAME` until they're replaced. Trigger a rolling
instance refresh on the PHP-FPM ASGs:

```bash
for OUTPUT_KEY in PHP74AutoScalingGroupName PHP83AutoScalingGroupName; do
  ASG=$(aws --profile ZI-Sandbox cloudformation describe-stacks \
    --stack-name "cf-scalable-web-$ENV-compute-php" \
    --query "Stacks[0].Outputs[?OutputKey=='$OUTPUT_KEY'].OutputValue" \
    --output text)
  echo "Refreshing $ASG..."
  aws --profile ZI-Sandbox autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG" \
    --preferences MinHealthyPercentage=50,InstanceWarmup=120
done
```

Rolling refresh takes ~5 min total with no downtime (ALB drains old
instances as new ones come healthy). Verify the new env is on the
replacement workers:

```bash
# from the deploy-host, against any healthy PHP instance via SSM:
aws --profile ZI-Sandbox ssm send-command \
  --instance-ids <php-instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cat /etc/php/*/fpm/pool.d/www.conf | grep DRUPAL_SITE_NAME"]'
```

### Verify Drupal answers

```bash
curl -sI "http://$ENV.envs.zoning-info.com/" | head -5
# Expect: HTTP/1.1 200 OK
# If you get "400 Bad Request — The provided host name is not valid",
# DRUPAL_SITE_NAME didn't reach the PHP-FPM workers yet.
```

### Unpublishing (e.g. before `make destroy-all`)

```bash
# Same JSON file with "Action": "DELETE" instead of UPSERT.
# DELETE for alias records requires the exact AliasTarget that's currently
# stored, so it's easiest to list-resource-record-sets first and copy the
# AliasTarget block verbatim.
aws --profile ZI-Sandbox route53 list-resource-record-sets \
  --hosted-zone-id "$ENVS_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='$ENV.envs.zoning-info.com.']"
# Build the DELETE change-batch with that exact AliasTarget, then submit.
```

---

## Pattern B — Per-env sub-zones (alternative; not recommended)

Documented here for completeness in case you need an env URL directly under
the apex (`sandbox.zoning-info.com` rather than `sandbox.envs.zoning-info.com`).

Same procedure as Pattern A, but each env gets its own delegation in the
parent zone:

1. For each env, create a hosted zone named `<env>.zoning-info.com` in
   ZI-Sandbox.
2. For each new zone, add an NS delegation record to the parent zone
   (`zoning-info.com`).
3. Publishing the ALB into the env's zone is then the apex record (`Name:
   "<env>.zoning-info.com."`) rather than a sub-record.

Tradeoffs vs Pattern A:

| Aspect | Pattern A (envs sub-zone) | Pattern B (per-env) |
|--------|---------------------------|---------------------|
| Parent-account work | Once | Once per env |
| Resulting URL | `sandbox.envs.zoning-info.com` | `sandbox.zoning-info.com` |
| Wildcard cert | One cert covers all envs (`*.envs.zoning-info.com`) | One cert per env, OR a wildcard at apex (security implications) |
| Future env addition | Workload-account-only | Requires parent-account access |

Pick B only if you have a specific reason the URLs need to live directly
under the apex (e.g. cookie domain inheritance, an existing brand
expectation, or external systems that already hard-coded `sandbox.zoning-info.com`).

---

## Troubleshooting

**`dig +short` returns nothing for `envs.zoning-info.com` NS records:**
- Parent zone delegation didn't take. Check with the parent-zone
  list-resource-record-sets command from Step 3.
- Recursive resolver cache: try `dig @8.8.8.8 +short NS envs.zoning-info.com`
  to bypass local cache.

**`dig +short sandbox.envs.zoning-info.com` returns the right IPs but the
ALB returns 400 Bad Request — invalid host:**
- Drupal's `trusted_host_patterns` doesn't include the new hostname.
- Confirm `DRUPAL_SITE_NAME` env var is set in PHP-FPM workers; restart them
  if not, then test again.

**Records exist in the sub-zone but no resolution:**
- Confirm the parent zone's NS delegation matches the sub-zone's actual NS
  servers. AWS auto-rotates NS assignments for new zones, so if you
  re-created the sub-zone, the NS values changed and the parent delegation
  is stale.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
