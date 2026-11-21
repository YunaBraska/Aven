---
name: artifact-inspection
description: Inspect, edit, convert, or validate documents, PDFs, spreadsheets, archives, and structured data when file-format behavior matters.
---

# Artifact inspection

Identify the real format from content and metadata rather than trusting only the extension. Preserve
the source unless the user explicitly requests in-place modification. Reuse an existing template,
style system, workbook structure, document hierarchy, formulas, links, and metadata when present.
Identify the authoritative version and properties that must survive the change. Compare the result
against them; do not silently alter accepted content, dimensions, appearance, or meaning.

Use a format-aware library or native tool already available in the environment. Extract the smallest
necessary content, avoid copying sensitive material into logs, and keep intermediate files in a
bounded temporary directory. Do not install a large dependency when an existing tool can perform the
operation reliably.

Validate the delivered artifact at its public boundary: reopen it with an independent parser when
practical, render layout-dependent formats, inspect the rendered result, and verify formulas or
structured values rather than trusting a successful write. Deliver the editable source plus an
export only when both are useful, and register the narrowest result path with assistant control.
