---
name: research-document-bundle-gaps
description: 4 of 12 zi_research_document bundles have no PHP bundle-class file — question for Zac whether they should have one or the calling code should be defensive.
metadata:
  type: project
---

# `zi_research_document` — bundle-class coverage gaps

Surfaced 2026-07-28 during end-to-end S3 media migration test on
sandbox. The migrated prod DB has 12 research-document bundles, but
the sandbox codebase (which is prod's codebase from a recent React2
snapshot) has PHP bundle-class subclass files for only 8 of them.

## Bundles WITH a bundle-class subclass (8)

Each of these has a `final class Xxx extends ResearchDocumentBundleBase`
at `web/modules/custom/zoning_info/modules/documents/src/Entity/ResearchDocument/`:

- `building_violations` → `BuildingViolations.php`
- `business_license` → `BusinessLicense.php`
- `certificate_of_occupancy` → `CertificateOfOccupancy.php`
- `condemnation` → `Condemnation.php`
- `fire_code_violations` → `FireCodeViolations.php`
- `historical_landmark` → `HistoricalLandmark.php`
- `zoning_letter` → `ZoningLetter.php`
- `zoning_violations` → `ZoningViolations.php`

All extend `ResearchDocumentBundleBase` (also in that folder), which
defines `getResearchAnswer()`.

## Bundles with NO subclass (4) — permit-type documents

DB entities exist for these bundles, but there's no matching PHP class:

- `conditional_use_permit`
- `planned_unit_development`
- `special_use_permit`
- `variance`

For any of these, Drupal instantiates the base `ResearchDocument` class
(via `bca` — the Bundle Class Annotations module), which does NOT
define `getResearchAnswer()`. Any code that calls `$doc->getResearchAnswer()`
on one of these instances throws `Error: Call to undefined method
Drupal\documents\Entity\ResearchDocument::getResearchAnswer()`.

## Where this actually blew up

Two call sites in `web/modules/custom/zoning_info/modules/report/` invoke
`getResearchAnswer()` directly (no `method_exists` guard):

- `src/Hook/ReportHooks.php:345` — inside `latexPreprocess()`; iterates
  `$research_entities` returned by
  `ResearchDocumentManager::getDocumentsForReport()` and calls
  `->getResearchAnswer()` on each. If the report references any of the
  four permit-type bundles, this line throws.
- `src/Entity/ConformanceAnalysisTrait.php:86` — same pattern.

Meanwhile, one call site DOES guard defensively (and works fine
regardless):
- `fannie/src/Service/FannieFieldResolver.php:329` —
  `method_exists($doc, 'getResearchAnswer') ? (string) $doc->getResearchAnswer() : ''`

That the FannieFieldResolver pattern uses `method_exists` suggests the
developer already knew this method might not exist on every research
document instance. But the equivalent guard was NOT applied to
`ReportHooks::latexPreprocess()` or the ConformanceAnalysisTrait.

## Questions for Zac (raise directly)

1. **Is the missing-subclass state intentional?**
   Should `variance`, `special_use_permit`, `planned_unit_development`,
   `conditional_use_permit` remain base-`ResearchDocument` instances
   (i.e., "these bundles don't have research answers, and calls to
   getResearchAnswer on them are illegal"), OR should each get a
   subclass with a bundle-appropriate implementation?

2. **If the first: should the calling code guard defensively?**
   `ReportHooks::latexPreprocess()` line 345 and
   `ConformanceAnalysisTrait::__someMethod__()` line 86 both call
   `getResearchAnswer()` without checking. Should they adopt the
   `FannieFieldResolver:329` pattern (`method_exists` guard, fall
   through to empty string)? If not, why does FannieFieldResolver
   guard but the others don't?

3. **If the second (each permit-type gets a subclass): what does
   `getResearchAnswer()` return for these?** Permits aren't binary
   yes/no like violations — they're documents with issue dates,
   conditions, etc. Would the return be a summary string, a URL, or
   something structurally different from the violation bundles' Yes/No?

## Where this surfaced in the codebase

- **Watchdog entry (sandbox, 2026-07-28)**: `wid` 98089-98093,
  `Error: Call to undefined method
  Drupal\documents\Entity\ResearchDocument::getResearchAnswer()`
- **Call chain**: hit `/admin/zoning-info/reports/conformance-reports/92284`
  after DB migration + bundle-class registration; report entity 92284
  references at least one bundle whose subclass exists (renders fine)
  and is trying to render the LaTeX preview which iterates ALL
  research documents (crashes on the permit-type ones).
