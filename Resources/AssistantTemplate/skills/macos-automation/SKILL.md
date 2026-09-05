---
name: macos-automation
description: Create, inspect, or repair macOS Shortcuts, Automator workflows, AppleScript, launch agents, or application automation.
---

# macOS Automation

Choose the least fragile mechanism that satisfies the request:

1. Use an application's documented CLI, URL scheme, API, or Shortcuts action when available.
2. Use Shortcuts for user-visible personal automation and existing Automator workflows when they
   already own the process.
3. Use AppleScript only for applications with an appropriate scripting dictionary.
4. Use UI scripting only as a last resort because it is localization-sensitive, accessibility-heavy,
   and brittle across releases.
5. Use a launch agent only for a real background lifecycle requirement with a clear unload path.

Keep scripts deterministic, parameterized, quoted, and free of embedded credentials. Bound retries,
time, output, and affected applications. Automation and Accessibility permissions require explicit
user intent and must be requested by the process that performs the action; never bypass or edit TCC.
Test with a reversible input and document how to stop or remove persistent automation.

Use installed dictionaries through Script Editor or `sdef`, installed manual pages, and current
Apple sources: [AppleScript Language Guide](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptX/)
and [Automator User Guide](https://support.apple.com/guide/automator/welcome/mac).
