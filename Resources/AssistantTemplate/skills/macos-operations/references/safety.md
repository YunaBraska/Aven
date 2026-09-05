# Safety and maintained sources

For cleanup, first resolve the exact bundle identifier and ownership. Relevant user-level locations
can include `~/Applications`, `/Applications`, `~/Library/Application Support`, `Caches`,
`Preferences`, `Containers`, `Group Containers`, `Saved Application State`, and `LaunchAgents`.
Their presence is evidence to inspect, not authority to delete. System-wide paths and shared group
containers require stronger proof and explicit user intent.

Use local manual pages (`man defaults`, `man plutil`, `man launchctl`, `man osascript`, `man open`)
for the installed macOS release. For current design, permissions, automation, and lifecycle behavior,
consult Apple Developer Documentation and the macOS Human Interface Guidelines:

- https://developer.apple.com/documentation/
- https://developer.apple.com/design/human-interface-guidelines/
- https://support.apple.com/guide/automator/welcome/mac

Prefer Shortcuts for user-visible personal automation when it provides the action; use Automator for
existing workflows and AppleScript for applications that expose an appropriate dictionary. UI
scripting is the last resort because it is permission-heavy and fragile across localization and UI
changes.
