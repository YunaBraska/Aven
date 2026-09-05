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
- Move a verified `~/VoiceAssistant` workspace to Aven's private `Historical Workspace` archive.
  Keep its historical path as a thread-ownership marker so explicit data deletion can still find
  Codex tasks created there.
- Retain narrow recognition of the old application bundle, executable, and preferences only for
  safe upgrade and explicit deletion.

## Consequences

- Existing database, credential metadata, recipes, pending messages, and context continue unchanged.
- Successful migration removes the old macOS storage name without creating a second vault.
- The historical workspace no longer remains as a visible home-directory folder, while its database
  and ownership evidence stay available inside Aven's private storage.
- A conflict remains visible and non-destructive; unrelated assistant capabilities continue to work.
