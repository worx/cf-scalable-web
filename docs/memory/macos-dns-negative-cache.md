---
name: macOS resolver negative-cache for newly-published DNS records
description: When `dig` resolves a new DNS record but `curl`/`ping`/Safari don't, it's macOS's mDNSResponder serving a cached NXDOMAIN. Flush with dscacheutil + killall.
type: reference
created: 2026-05-23
---

# macOS Resolver Negative-Cache Gotcha

## The signature

`dig` and `curl` (or `ping`, or Safari) disagree on whether a hostname
exists. Specifically:

- `dig +short sandbox.envs.zoning-info.com` → returns IPs ✅
- `dig +short @8.8.8.8 sandbox.envs.zoning-info.com` → returns IPs ✅
- `curl https://sandbox.envs.zoning-info.com/` → `Could not resolve host` ❌
- `ping sandbox.envs.zoning-info.com` → `Unknown host` ❌
- Safari → cannot connect, name resolution failure ❌

If you see this pattern, **stop debugging the DNS record / the ALB /
the cert / nginx** — the actual DNS infrastructure is fine. macOS's
local resolver is the culprit.

## Why it happens

macOS uses `mDNSResponder` (formerly `discoveryd`) as its system
resolver. When a name lookup returns NXDOMAIN (host doesn't exist),
mDNSResponder caches that negative answer for the negative-TTL
specified in the SOA record of the parent zone — typically 60-300s,
sometimes up to 24h depending on the parent zone's config.

If you (or any tool — a smoke test, a browser, a prior dig probe)
asked for the name BEFORE the DNS record was published, the NXDOMAIN
got cached. After the record is published, `dig` queries DNS servers
directly and sees the new record. But `curl`/`ping`/Safari go through
`mDNSResponder`, which serves them the cached NXDOMAIN until the
negative-TTL expires.

Authoritative DNS being correct ≠ your local resolver being correct.

## The fix

```bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

Run both — `dscacheutil -flushcache` clears the userland cache;
`killall -HUP mDNSResponder` signals the resolver daemon to reload.
Either alone is sometimes insufficient.

After running, `curl`/`ping`/Safari should immediately see the new
record (or correctly receive NXDOMAIN if the name truly doesn't exist).

## How to detect this case programmatically

If `dig +short <name>` succeeds but `curl https://<name>/` returns
exit code 6 ("could not resolve host") OR HTTP 000, suspect this.
Confirm by running curl with `--resolve <name>:443:<IP>` (using an
IP from dig's output) — if that succeeds, it's definitely the OS
resolver cache, not the network.

`make smoke-test-public ENV=...` already implements this diagnostic:
on HTTP 000, it retries with `--resolve` pinning, and if the pinned
attempt succeeds, prints the flush commands. Past incident: 2026-05-23,
fresh deploy-allX cycle. Diagnostic added in that session.

## Why we can't fully prevent it from inside the tooling

`publish-dns` already waits for Route 53 INSYNC and verifies
resolution via `dig @8.8.8.8` (bypassing the local resolver) before
returning. That ensures the authoritative DNS is correct. But it
cannot reach into macOS's mDNSResponder cache to invalidate a
previously-cached NXDOMAIN — that's a OS-level operation requiring
sudo, and we don't want our smoke tests demanding sudo.

So: prevention isn't possible, detection + clear guidance is the
best we can do.

## Linux equivalents (when the operator is not on macOS)

Most modern Linux distros with systemd-resolved:
```bash
sudo resolvectl flush-caches
```

Or restart the resolver:
```bash
sudo systemctl restart systemd-resolved
```

Older distros with `nscd`:
```bash
sudo systemctl restart nscd
```

`smoke-test-public` shows macOS commands when `uname -s` is `Darwin`,
generic Linux guidance otherwise.

## Adjacent: stale POSITIVE-cache after a destroy/redeploy

The flip side of negative-caching also bites: after `destroy-all`,
the ALB's old IPs are gone. After `deploy-allX` + `publish-dns`,
a new ALB has new IPs. Your Mac's resolver may serve the OLD IPs from
positive cache until that TTL expires — and curl will get connection
timeouts (not 000, but actual `Connection refused` / `Operation timed
out`).

Same fix: flush the resolver cache.
