---
name: macos-preferences
description: Inspect or change macOS defaults, property lists, application preferences, and related System Settings with bounded native tools.
---

# macOS Preferences

Identify the installed macOS version, target application, bundle identifier, preference owner, and
whether the setting is user, host, managed, or system scoped. Read the current value before changing
it and preserve its data type.

- Use `defaults read <domain> <key>` for preference-domain access and `plutil` for structured plist
  inspection, validation, and targeted editing. Do not parse the human-oriented output of a broad
  `defaults read` as a stable serialization format.
- Resolve bundle identifiers from the real application bundle rather than guessing. Check whether a
  configuration profile or managed preference owns the value before trying to override it.
- Change one domain and key at a time, then read it back. Restart only the smallest relevant process
  when the application genuinely requires it; do not broadly kill preference services.
- Treat hidden or undocumented keys as version-sensitive. Verify them against the installed system,
  current primary documentation, or observable app behavior and state the uncertainty.
- Never use `sudo`, delete a whole preference domain, or reset unrelated settings unless the user
  explicitly requests that exact destructive scope.

For current behavior, prefer installed manual pages (`man defaults`, `man plutil`) and
[Apple Developer Documentation](https://developer.apple.com/documentation/).
