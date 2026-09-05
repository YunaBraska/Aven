# ADR 0016: Aven Application Support migration

## Status

Accepted

## Context

The application, bundle identifier, and preferences domain use the Aven name, but early builds stored
the workspace, database, vault metadata, pending input, and process lock under `Voice Assistant`.
Deleting that directory would lose user-owned context and could split one credential vault into two.

## Decision

- The canonical private storage root is `~/Library/Application Support/Aven`.
- Before acquiring the GUI process lock, move the complete legacy directory atomically when the Aven
  directory does not exist.
- Reject symbolic-link or non-directory sources. If both directories contain data, preserve both and
  expose a warning instead of guessing how to merge them.
- Remove an empty legacy directory when the canonical directory already exists.
- Retain narrow recognition of the old application bundle, executable, preferences, and verified
  `~/VoiceAssistant` workspace only for safe upgrade and explicit deletion.

## Consequences

- Existing database, credential metadata, recipes, pending messages, and context continue unchanged.
- Successful migration removes the old macOS storage name without creating a second vault.
- A conflict remains visible and non-destructive; unrelated assistant capabilities continue to work.
