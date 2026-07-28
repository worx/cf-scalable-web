---
name: pdf-generation-lambda-candidates
description: Two Drupal routes do live PDF/document generation synchronously on PHP-FPM and time out on our small instances. Both are Lambda migration candidates. Don't try to fix by growing the PHP boxes.
metadata:
  type: project
---

# PDF generation → Lambda punt (do not grow PHP instances)

Two Drupal routes trigger synchronous heavy document generation on
PHP-FPM. Both time out (504) on our small sandbox instances. Both are
architecturally in the same bucket: **should run on Lambda, not on the
web-serving PHP-FPM fleet.**

## The two routes

### 1. `/zoning-info/conformance-report/{id}/latex-preview`
- Custom controller in `report` module
- Calls `LatexGenerator->renderTemplate()` (likely spawns `pdflatex`
  or `latexmk` — we haven't confirmed which, but the route name +
  `.tex.twig` templates in the codebase strongly imply LaTeX)
- Sandbox PHP AMIs deliberately DO NOT have LaTeX installed —
  Kurt: "far too much of a memory impact on these small machines"
- Additional bug: template references `report.content.use` which
  no sandbox code populates (may be a real bug on Zac's side)

### 2. `/print/pdf/commerce_order/{id}` (entity_print module)
- Provided by `entity_print` module (8.x-2.18)
- Configured engine: **DomPDF** (pure PHP, no external binary)
- Despite being pure PHP, still 504s on sandbox — the PHP-side
  work of rendering a complex order to PDF exceeds either the ALB's
  60s idle timeout or the instance's ~900MB memory
- Trap for the operator: button label reads "View PDF" but it's
  actually **generating** a PDF live, not serving a stored file.
  Different route + different failure mode from the S3-served PDFs
  under `/_flysystem/s3/...` (those work fine — pre-existing files
  streamed straight from the media bucket).

## Common failure signature

Both fail with HTTP 504 Gateway Timeout after ~60s. ASG/ALB/FPM
infrastructure is healthy; the request itself just takes too long
(or OOM-kills the FPM worker) to complete before the ALB gives up.

## Why NOT to fix by resizing PHP boxes

- Every 504-fix increase (instance size, ALB timeout, PHP memory
  limit, dompdf resource limits) leaves the base architecture wrong:
  a synchronous request handler blocking a web worker for tens of
  seconds while it generates a document.
- Under real load, even bigger instances FPM-pool-exhaust when
  many users hit "View PDF" at once. Web serving degrades for all
  requests, not just PDF ones.
- Growing sandbox to match masks the problem that will resurface
  in staging/prod at higher scale.

## The right shape

Generate PDFs on **Lambda** (or a background queue):
- Web request enqueues the generation job, returns immediately
  ("your PDF is being prepared, we'll email you the link" — or
  polls a job-status endpoint)
- Lambda function does the actual generation with a bigger memory
  budget and a longer timeout than any web request
- Result stored in S3, served via a presigned URL (same pattern
  as the s3:// files that already work)

## Decision status

**Deferred pending Lambda architecture decision** (2026-07-28). Do
not attempt to "just fix" either 504 in the interim by resizing
compute or extending timeouts — mark as expected on sandbox until
the Lambda path is designed.

Related: [[php74-php83-storage-divergence]] — the same
"don't grow the instances to match" reasoning that keeps php74 on
EBS instead of trying to make S3 work there.
