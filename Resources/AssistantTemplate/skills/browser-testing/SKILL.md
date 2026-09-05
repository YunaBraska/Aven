---
name: browser-testing
description: Test or diagnose web interfaces through public browser behavior with Playwright or an existing equivalent when navigation, interaction, rendering, accessibility, or cross-browser evidence matters.
---

# Browser testing

Inspect the repository's existing browser-test runner, package manager, configuration, supported
browsers, and application startup command before changing anything. Reuse an existing Playwright,
Cypress, WebDriver, or framework-native suite. Prefer Playwright when the project already uses it or
the user explicitly requests it; do not add a browser-test dependency merely because this skill was
selected.

Test observable behavior through stable user-facing roles, labels, and public URLs. Avoid coupling
tests to internal component state, CSS implementation details, arbitrary delays, or generated DOM
structure. Use the real local application and owned backend where practical. Fake only external
systems outside the project's control, at their network boundary.

Cover relevant states rather than producing a screenshot tour: keyboard operation, focus, loading,
empty, success, validation, failure, retry, responsive layout, and reduced motion when they can
affect the requested behavior. Automated accessibility scanning is useful but does not replace
keyboard, screen-reader, contrast, zoom, and human checks.

Keep runs deterministic and isolated. Use the runner's web-server lifecycle instead of an
uncontrolled background process. Capture traces, screenshots, or video on failure or first retry,
not on every successful run unless the user asks. Artifacts may contain secrets and personal data;
keep them local, bounded, and out of source control unless intentionally published.

When diagnosing a failure, report the first user-visible divergence, its reproduction command, and
the smallest relevant artifact. Do not mask instability with retries; use retries only to measure
or contain a known external source of nondeterminism.

Authoritative references:

- [Playwright test configuration](https://playwright.dev/docs/test-configuration)
- [Playwright web-server lifecycle](https://playwright.dev/docs/test-webserver)
- [Playwright traces](https://playwright.dev/docs/trace-viewer)
- [Playwright accessibility testing](https://playwright.dev/docs/accessibility-testing)
