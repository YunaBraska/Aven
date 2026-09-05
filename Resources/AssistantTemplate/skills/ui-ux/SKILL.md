---
name: ui-ux
description: Design, implement, or review user interfaces with platform-native interaction, accessibility, responsive behavior, and restrained visual hierarchy.
---

# UI and UX

Identify the platform, users, primary task, information shape, existing design system, and supported
devices before choosing components. Preserve established product language and navigation.

- Prefer native controls and familiar platform patterns over decorative custom interaction.
- Make keyboard navigation, focus order and visibility, accessible names, screen-reader output,
  contrast, text scaling, reduced motion, and target sizes part of the implementation—not a later pass.
- Design loading, empty, error, offline, permission-denied, partial-success, and completed states.
- Keep layout stable. UI rendering reads cached snapshots; paint, hover, scroll, focus, and layout do
  not trigger network or storage work.
- Use color and animation to communicate state, not as noise. Respect reduced-motion settings.
- Match the layout to the content: conversations, lists, media, forms, dashboards, and spatial tools
  do not share one universal card grid.
- Test the actual interaction boundary with keyboard and assistive technology where practical.

For platform decisions and current standards, read [design systems and sources](references/design-systems.md)
and only the section relevant to the target. Do not combine Apple HIG, Material, and web conventions
into a hybrid interface unless the product genuinely spans those platforms.
