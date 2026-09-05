---
name: diagram-workbench
description: Create or update editable architecture, process, data-flow, state, and relationship diagrams when a visual materially clarifies structure or sequence.
---

# Diagram workbench

Use a diagram only when it communicates relationships better than short prose or a small table.
Default to an editable `.drawio` file containing uncompressed draw.io XML. Use Excalidraw JSON only
when the user explicitly wants a loose whiteboard or sketch aesthetic. Use Mermaid only when an
existing project convention requires it or the user wants an ephemeral inline diagram.

Before drawing, inspect existing documentation and diagram conventions. Preserve an existing visual
language when present. Keep one clear reading direction, short labels, consistent shapes, generous
spacing, and the fewest connectors that preserve meaning. Do not turn prose into decorative boxes.

For a new draw.io artifact:

1. Choose a durable path beside the project documentation or requested output.
2. Write valid uncompressed `mxGraphModel` XML with unique cell IDs, explicit geometry, labelled
   connectors, and meaningful page names.
3. Validate the XML with an available parser such as `xmllint --noout`; do not assume a tool path.
4. Register the file with `assistant-control result set <absolute-path>`.
5. When the user asks to open or edit it, run
   `assistant-control diagram open <absolute-drawio-path>`.

The app validates small draw.io files and asks for one-shot confirmation naming the file before it
opens the browser editor through a URL fragment. The fragment is not part of the HTTP request, but
browser page code can read it. Do not open diagrams containing secrets, credentials, or sensitive
personal data in a third-party web editor without explicit informed direction. Keep those artifacts
local and reveal the file instead.

When updating a diagram, preserve stable IDs and untouched layout where practical. Verify that every
edge has a valid source and target, text is not clipped, the main flow remains obvious at a glance,
and the source stays editable. Export PNG, SVG, or PDF only as an additional delivery format, never as
the sole source when future editing is expected.
