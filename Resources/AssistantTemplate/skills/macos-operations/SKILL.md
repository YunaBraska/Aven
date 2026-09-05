---
name: macos-operations
description: Coordinate a cross-cutting macOS task that spans preferences, application lifecycle, automation, permissions, or user services.
---

# macOS operations

Use this skill when a macOS task crosses more than one focused boundary. For a focused task, prefer
`.agents/skills/macos-preferences/SKILL.md`, `.agents/skills/macos-app-lifecycle/SKILL.md`, or
`.agents/skills/macos-automation/SKILL.md`. Inspect the OS version, architecture, relevant app bundle, launch
service, permissions, and available executables before choosing a mechanism.

- Read a `defaults` domain/key before changing it, write only the targeted value, then read it back.
  Do not treat `defaults` output as a stable plist serialization API.
- Use `plutil` for plist validation and structured edits, `launchctl` for launch-service inspection,
  `open`/`NSWorkspace` for app launching, and `osascript` or Automator only when UI/application
  automation is actually required.
- AppleScript and UI scripting require explicit user intent and the corresponding Automation or
  Accessibility permission. Do not bypass a denied permission.
- Before uninstalling or cleaning an app, inventory the bundle, receipts, containers, group
  containers, preferences, caches, saved state, launch agents, helpers, login items, and relevant
  System Settings entries. Distinguish app-owned disposable data from user documents and shared data.
- Preview cleanup and prefer Trash or another recoverable operation. Never use broad recursive
  deletion, `sudo`, or guessed bundle identifiers.
- Quote paths, bound discovery, redact personal data and secrets, and verify the observable result.

Read [safety and source notes](references/safety.md) for cleanup, launch services, AppleScript, or
Automator work. Re-check linked Apple documentation when platform behavior may have changed.
