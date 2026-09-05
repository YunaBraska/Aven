# Design systems and maintained sources

Read only the target platform's material and verify it when platform guidance may have changed.

## Apple platforms

Use Apple Human Interface Guidelines and native frameworks. On macOS, menu-bar utilities should be
quiet at rest, expose concise status and direct actions, use SF Symbols where appropriate, respect
Reduce Motion, and avoid persistent windows without a task that needs one.

- https://developer.apple.com/design/human-interface-guidelines/
- https://developer.apple.com/accessibility/

## Android

Use the current Material Design guidance and platform components. Preserve Android navigation,
back behavior, typography, dynamic color, and accessibility semantics.

- https://m3.material.io/
- https://developer.android.com/guide/topics/ui/accessibility

## Web

Use semantic HTML before ARIA, progressive enhancement, responsive layout driven by content, and
the project's design tokens. Follow WCAG at the conformance level required by the product and
jurisdiction.

- https://www.w3.org/WAI/standards-guidelines/wcag/
- https://www.w3.org/WAI/ARIA/apg/
