# ADR 0009: Native automation and metadata build

## Status

Accepted

## Context

App Intents written in Swift compile with the AppIntents framework, but macOS cannot discover them
unless the application bundle also contains Xcode-generated intent metadata.

## Decision

Aven publishes one parameterized control intent and one text-submission intent. Both call the same
application actions and conversation queue used by the menu, shortcut, and voice controls. The
checked-in Xcode project owns the production build so Apple's metadata processor emits
`Metadata.appintents`. The shell build remains the stable entrypoint for tests, icon generation,
ad-hoc signing, and verification.

## Consequences

- Shortcuts can discover Aven controls without a parallel control implementation.
- Building requires Xcode, but no project generator or third-party dependency at runtime.
- `project.yml` is the editable project definition; contributors regenerate the checked-in project
  with XcodeGen only when the definition changes.
