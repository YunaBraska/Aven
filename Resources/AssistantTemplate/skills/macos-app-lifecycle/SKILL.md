---
name: macos-app-lifecycle
description: Inspect, install, update, repair, or remove a macOS application and its owned leftovers without deleting shared or user-created data.
---

# macOS App Lifecycle

Resolve the exact application URL, bundle identifier, signature, installation mechanism, running
processes, helpers, and receipts before changing anything. Follow the package manager or vendor's
documented lifecycle when one exists.

For cleanup, inventory only plausible app-owned locations: application bundles, receipts, user and
system Application Support, caches, preferences, containers, group containers, saved state, launch
agents or daemons, privileged helpers, login items, and relevant privacy or extension registrations.
Presence is evidence to inspect, not authority to delete.

- Distinguish disposable cache/state from user documents, shared group data, databases, exports,
  plugins, and credentials.
- Stop the app and its proven helpers cleanly before mutation.
- Preview exact targets and prefer Trash or the product's uninstaller. Use explicit standardized
  paths; reject symlinks, ambiguous ownership, broad globs, and guessed bundle identifiers.
- Do not use recursive deletion, `sudo`, receipt forgetting, TCC database edits, or System Settings
  manipulation without an explicit request and a verified exact target.
- Verify the observable result and report anything intentionally retained.

Re-check [Apple deployment and bundle guidance](https://developer.apple.com/documentation/)
when current platform behavior matters.
