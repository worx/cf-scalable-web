---
name: php74-php83-storage-divergence
description: The php74 and php83 PHP-FPM pools use intentionally different media/file storage strategies — 74=EBS (2TB+ legacy), 83=S3 (flysystem_s3). Not a bug or migration in-progress, this is the target architecture.
metadata:
  type: project
---

# PHP 7.4 / 8.3 pool storage strategies are intentionally different

Fact: the php74 and php83 PHP-FPM pools in this project use different media/file storage architectures **by design**, not by transitional accident. Both are the intended long-term state.

- **php74 pool** — media/uploads live on **EBS**, with a working set of ~2 TB. This is the legacy path for content that predates the S3 migration. It stays around indefinitely to keep pre-existing legacy content served without a rewrite.
- **php83 pool** — media/uploads live on **S3** via Drupal's `flysystem_s3` module, keyed by env var `AWS_S3_BUCKET`. This is the go-forward architecture — smarter for scale, cheaper at rest, decoupled from instance disk.

## Why

Kurt characterized php74 as "legacy only — kept to keep old stuff running, not for new stuff." The EBS scale-out cost (2 TB+ per replica, snapshots, cross-AZ) is exactly what motivated switching new content onto S3. Rewriting existing php74-served content into S3 URIs would be an unrelated project — not worth doing for content that's not accreting.

## How to apply

- **Don't try to "unify" the two storage models** or normalize php74 to match php83 unless the user explicitly asks. The divergence is architectural intent, not tech debt.
- **When wiring S3-related config**, expect it to apply to php83 first — that's where every new S3 feature lands.
- **When touching php74**, treat it as a stable maintenance surface — no new features expected. Suggestions like "we could also add this to php74" should be paired with an explicit "worth doing?" flag, not implemented reflexively.
- **In multi-pool cycles (AMI rebuilds, instance refreshes, config pushes)**, it's often correct to skip php74 for changes that only benefit the S3-based path (e.g., `AWS_S3_BUCKET` env var). Not an omission — a scope decision.

Related: [[test-environment-design]] describes the sandbox → staging → prod promotion flow; this memory clarifies that once php83 lands in prod, php74 does NOT then get retrofit — it stays as-is with its EBS backing.
