# LaTeX-on-Lambda — Meeting Outcomes (2026-08-13)

> **Companion to** [`latex-on-lambda-2026-08-13.tex`](./latex-on-lambda-2026-08-13.tex) / [`.pdf`](./latex-on-lambda-2026-08-13.pdf).
> The full PDF has the pre-meeting options landscape (chapters 1–8) plus per-option
> technical appendices. This Markdown summarizes only the **decisions and design
> choices confirmed in the 2026-08-13 meeting** — for Obsidian and IDE navigation.
>
> Both documents carry the same meeting content; diagrams here use Mermaid
> (native in Obsidian and GitHub) so they render inline in the tools you use daily.

## Attendees and Context

Four attendees:

- **Zac Hudson** — client Drupal developer; owner of the existing Docker-based LaTeX generation code; author of the current `Document Service latex Generator`
- **Kurt Vanderwater** — WorxCo operations/infrastructure; owner of the scalable AWS architecture
- **Pat Shaughnessy** — author of the original 2024 Lambda LaTeX MVP; observer plus institutional reference
- **Tim Houseman** — observer / team member

Meeting was one hour; approximately half was Lambda-focused technical discussion; the rest covered adjacent operational topics (Postgres, multi-tenancy roadmap, order/pricing walkthrough) not summarized here.

---

## Decisions Confirmed

### 1. Execution model: Lambda

Lambda selected. App Runner ruled out (roughly **2× the cost** with no compelling
advantage). Fargate, Batch, and dedicated EC2 ASG deferred without further
consideration — Lambda's scale-to-zero, pay-per-invocation, and image-based
deployment shape fit the workload and existing operational patterns.

### 2. Container: fresh build, not from MVP

Pat's 2024 MVP is architectural inspiration only. Too much has changed
(TeX Live version, Lambda container-image support maturity, `latexmk` auto-iteration)
to make direct code reuse worthwhile. The new container is a clean build.

### 3. Container lifecycle: Image Builder pipeline

The Lambda container image will be built and refreshed via an **ECR-container
Image Builder pipeline**, symmetric with the existing nginx/php83 AMI pipelines.

- **Default cadence: monthly rebuild** on the current base image with fresh package versions
- **On-demand trigger** available for CVE response, new TeX Live releases, or template dependency changes
- Ghostscript's CVE history alone justifies the automated refresh

### 4. Delivery: staging-bucket clone with lifecycle

The finished PDF is written to **two locations**:

- **Production S3 bucket** — keeps the PDF **forever** as the canonical record
- **Staging S3 bucket** (only when large-file delivery via presigned URL is needed) — object auto-expires after **10 days**; presigned URL valid for **max 7 days** (always shorter than the object's remaining lifetime)

Compared to presigning against the production bucket directly, this pattern gives:

- Smaller blast radius on a leaked URL (points at a file that's going away anyway)
- Auditable "what is currently externally accessible" view (the staging bucket **is** the list)
- Ability to revoke access surgically (delete the staging object) without rotating keys
- Clean compliance story: no production data leaves the private bucket

---

## Payload Contract

**Three required parameters** on every Lambda invocation. All required — Zac's phrasing:

> *"if you don't tell me how to notify you when I'm done, I don't want to talk to you at all."*

| Parameter | Purpose |
|---|---|
| `input_zip_url` | S3 URL of the input zip that Drupal has built and uploaded. Contains everything the Lambda needs to compile: main `.tex` file, `.sty` style files, all PDFs to be included, plus any per-report font files not already baked into the container. |
| `output_pdf_url` | S3 URL where the finished PDF should be written. Drupal decides the exact path (including any date prefix, tenant prefix, etc.) so name collisions are Drupal's problem, not Lambda's. Also becomes the "handle" by which Drupal tracks the job. |
| `callback_url` | HTTP endpoint Drupal exposes to receive the "done" notification when Lambda finishes. Different Drupal modules (report, invoice, future residential) may register different endpoints. |

The callback message contains at minimum the same `output_pdf_url` value that
Drupal supplied on invocation — self-contained, so Drupal tracks correlation
by destination filename with no separate correlation ID needed.

---

## End-to-End Flow

```mermaid
sequenceDiagram
    autonumber
    participant D as Drupal
    participant SI as S3 Input
    participant L as Lambda
    participant SP as S3 Production
    participant SS as S3 Staging
    participant C as Customer

    D->>SI: upload zip (tex + sty + PDFs + fonts)
    D->>L: invoke Lambda (input_zip_url, output_pdf_url, callback_url)
    L->>SI: pull zip
    Note over L: unzip → /tmp<br/>qpdf --check<br/>ghostscript (if needed)<br/>latexmk (lualatex)
    L->>SP: write canonical PDF (kept forever)
    opt large-file delivery
        L->>SS: clone PDF to staging (10-day lifecycle)
    end
    L->>D: POST callback_url (output_pdf_url + delivery info)
    Note over L: container dies
    D->>SS: issue presigned URL (7-day max)
    D-->>C: email presigned URL (large) OR attach PDF (small)
```

---

## Lambda Container Contents

```mermaid
flowchart TB
    subgraph Base["Base image (AL2023 / Ubuntu)"]
        direction TB
        subgraph Toolchain["LaTeX toolchain"]
            TL["TeX Live 2025+"]
            LL["lualatex"]
            LM["latexmk"]
        end
        subgraph PDF["PDF preprocessing"]
            QP["qpdf"]
            GS["ghostscript"]
        end
        Fonts["Preloaded fonts"]
        Entry["Custom entrypoint script"]
    end

    style Base fill:#dbeafe,stroke:#3b82f6
    style Toolchain fill:#ecfeff,stroke:#0891b2
    style PDF fill:#fef3c7,stroke:#d97706
```

**Invocation contract**: 3 required params (`input_zip_url`, `output_pdf_url`, `callback_url`).

TeX Live provides `lualatex` + `latexmk`. QPDF and Ghostscript preprocess incoming PDFs.
Fonts and the entrypoint script complete the image.

---

## Storage Architecture

```mermaid
flowchart LR
    D[Drupal]
    L[Lambda]
    C[Customer]

    subgraph Buckets["S3 buckets (all private)"]
        direction TB
        SI["📦 S3 Input Bucket<br/>job zips<br/>(short-lived)"]
        SP["📄 S3 Production Bucket<br/>canonical PDFs<br/>(keep forever)"]
        SS["📤 S3 Staging Bucket<br/>delivery copies<br/>(10-day lifecycle)"]
    end

    D -- upload zip --> SI
    SI -- pull zip --> L
    L -- write canonical --> SP
    L -- clone if needed --> SS
    SS -. presigned URL<br/>7 day max .-> C

    style SI fill:#fed7aa,stroke:#c2410c
    style SP fill:#fed7aa,stroke:#c2410c
    style SS fill:#fed7aa,stroke:#c2410c
```

**Three-bucket model** — input bucket holds job payloads, production bucket keeps the
canonical PDF forever, staging bucket receives a copy only when large-file delivery via
presigned URL is required. Objects auto-expire after 10 days, presigned URLs valid for
max 7 days — URL always expires before the underlying object.

---

## Image Builder Pipeline

```mermaid
flowchart LR
    Cron["📅 monthly cron<br/>(default cadence)"]
    OD["🚨 on-demand trigger<br/>(CVE, TeX Live update)"]
    Src["📁 Source<br/>Dockerfile in git"]
    Build["🔨 Build<br/>docker build"]
    Test["✅ Test<br/>hello-world.tex compile"]
    Pub["📤 Publish<br/>push to ECR"]
    Lam["λ Lambda function<br/>updated to use new image tag"]

    Cron --> Build
    OD --> Build
    Src --> Build
    Build --> Test
    Test --> Pub
    Pub --> Lam

    style Cron fill:#fef3c7,stroke:#ca8a04
    style OD fill:#fef3c7,stroke:#ca8a04
    style Src fill:#dcfce7,stroke:#16a34a
    style Build fill:#dcfce7,stroke:#16a34a
    style Test fill:#dcfce7,stroke:#16a34a
    style Pub fill:#dcfce7,stroke:#16a34a
    style Lam fill:#e0e7ff,stroke:#4338ca
```

**ECR-container Image Builder pipeline** for the Lambda LaTeX image. Monthly cadence
by default; on-demand trigger for CVE response or toolchain updates. Symmetric with
existing nginx/php83 AMI pipelines — reuses operational patterns.

---

## Applies-to Breadth

The Lambda infrastructure is **not report-specific**. Same pipeline serves multiple
document types, each potentially with its own callback endpoint:

- **Conformance reports** (the original driver; commercial today)
- **Invoices** (already LaTeX-generated in Zac's current Docker path)
- **Future: residential-market documents** (same code base, new Drupal module)

Each caller supplies its own `callback_url` at invocation time, so a single Lambda
function serves all three with per-module completion routing.

---

## Action Items

### Zac's TODO

- [ ] Send Kurt the path to the current `Document Service latex Generator` implementation (Docker-based)
- [ ] Send Kurt the current Drupal invocation points (where the code today calls into the Docker LaTeX pipeline) — Kurt uses this to build the patches that Drupal will need to redirect calls at Lambda
- [ ] Design the callback endpoint schema (payload shape, HTTP verbs, error semantics)
- [ ] Design the Drupal-side submission flow: build zip, upload to S3 input bucket, invoke Lambda with three params
- [ ] Add outstanding-jobs tracking to Drupal (a small table; up to ~1000 rows expected under residential load)
- [ ] Start work **next week** (2026-08-18 or later)

### WorxCo's TODO

- [ ] Build the Lambda container image (fresh, not from MVP): TeX Live 2025+, `lualatex`, `latexmk`, QPDF, Ghostscript, preloaded fonts, entrypoint script
- [ ] Build the ECR-container Image Builder pipeline with monthly + on-demand triggers
- [ ] Provision the three S3 buckets: input, production PDFs, staging (with 10-day lifecycle rule)
- [ ] Build the Lambda function + invocation-URL infrastructure that accepts the three-parameter call
- [ ] Provide Zac the Lambda invocation spec (HTTP endpoint URL, expected parameters, callback contract)
- [ ] Provide Zac the S3 write credentials/roles for the input bucket

---

## Notes and Clarifications from the Meeting

- **LaTeX has no stream-wrapper support** — files must be local on disk. This is why
  the zip payload pattern is necessary; Lambda unzips into `/tmp` before running `latexmk`.
- **Toolchain is `lualatex` specifically**, not `pdflatex` or `xelatex`. Some included prod PDFs
  have quirks that only `lualatex` handles cleanly.
- **PDF preprocessing is two-stage**: `qpdf --check` on every input PDF; if it flags issues,
  run Ghostscript to normalize the PDF (strips extra content, may bump version). QPDF is
  fast at checking; Ghostscript is thorough at rewriting.
- **Fonts baked into the base container** for the shared set. Per-report font overrides
  can travel in the zip if needed.
- **Cost expectation (current-reality math)**: **current commercial volume is 200–500 reports/month** — not the aspirational 20K/month residential projection. Using an average of **250 reports/month at ~250 pages each** (Zac's reports run heavy), Lambda compute cost lands at roughly **$1–3/month** for actual invocations, plus a few dollars/month for Image Builder + ECR storage + S3 buckets. **Total realistic monthly bill for current-state operations: ~$5–10/month.** The 20K/month figures in the PDF's chapter 7 cost table remain valid **capacity projections** for the residential pivot when/if it materializes, not a current billing forecast. Also worth noting: at 250/mo (roughly 8/day), **every invocation is essentially a cold start** — 5–10 seconds of latency added to each report generation for the container spin-up. Not a problem for the async fire-and-callback flow, but a latency floor to be aware of.
- **Migration status of Docker in production**: the Docker LaTeX container was *not* migrated
  as part of the recent sandbox rebuild — production still runs the old Docker path. Zac
  needs to identify all the Drupal call sites so Kurt can prepare the patches that redirect
  them at Lambda.

---

## Cross-References

- Full pre-meeting options landscape + per-option technical appendices: [`latex-on-lambda-2026-08-13.pdf`](./latex-on-lambda-2026-08-13.pdf) (chapters 1–8 and appendices A–G)
- LaTeX source for the PDF: [`latex-on-lambda-2026-08-13.tex`](./latex-on-lambda-2026-08-13.tex) — chapter 9 mirrors this Markdown
- Related planning notes (pre-meeting):
  - [`docs/memory/pdf-generation-lambda-candidates.md`](../memory/pdf-generation-lambda-candidates.md)
  - [`docs/memory/phase-d-backlog.md`](../memory/phase-d-backlog.md)
  - [`docs/memory/research-document-bundle-gaps.md`](../memory/research-document-bundle-gaps.md)
- Meeting transcript (source): [`docs/Transcripts/2026-08-13 Meeting with Zac RE: LaTeX on Lambda for Zoning`](../Transcripts/)
