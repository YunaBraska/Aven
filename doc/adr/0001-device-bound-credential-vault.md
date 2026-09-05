# ADR 0001: App-scoped macOS Keychain credential store

## Status

Accepted; replaces the custom file-encryption design.

## Context

The assistant needs credentials, TOTP seeds, and short-lived browser-session exports without putting
secret values in prompts, memory, recipes, logs, or its database. A separate assistant login would
interrupt the menu-bar workflow. A custom cryptographic vault also creates unnecessary key lifecycle
and recovery code.

## Decision

Store secret bytes as generic-password items in macOS Keychain. Every query is constrained to the
fixed service `com.yunabraska.aven.credentials.v1`; each record ID is the Keychain account.
A distribution signed with an authorized app identifier uses the Data Protection Keychain, the
app's default private access group, disabled synchronization, and `WhenUnlockedThisDeviceOnly`.
Apple rejects that store for ad-hoc builds, so local unsigned development builds fall back to the
login Keychain and its creator-app ACL. Do not request or enumerate the user's existing passwords.

Keep only non-secret metadata under Application Support: record ID, purpose, service, account, kind,
source, provenance, timestamps, and expiry. Store the SHA-256 digest of the canonical metadata beside
the secret in its app-private Keychain value. Every metadata read must match that authoritative digest
before the app may list, refresh, expire, or use the record. This detects both edited files and replay
of older valid metadata; file permissions alone are not an integrity boundary. Codex does not receive
direct filesystem access to this directory. It lists, imports, refreshes, removes, and uses records
through the fixed app broker. The broker never exposes a raw-secret command and scrubs literal and
Base64 forms from child output.

Version 2 and 3 records may migrate automatically only when they contain no source, executable scope,
or expiry. Those identity-bound, authority-free records are wrapped with a version 4 digest on first
read. Legacy metadata carrying any authority or lifetime field fails closed and requires explicit
re-import, because authenticating an existing unprotected scope would merely preserve possible
tampering.

Browser sessions default to 12 hours and may not exceed seven days. A locked Keychain blocks only
the credential-dependent operation. Ordinary conversation and local work continue.

Reinstalling or updating the app reuses the fixed service, bundle identifier, metadata directory,
and records. It must not create a new vault. Per-task capability grants remain a separate boundary
from standing exact-command scopes.

Provide a two-step `Delete Assistant Data` menu action. It deletes only the fixed Keychain service,
stored assistant Codex tasks, the app's Application Support directory, and preferences. Deleting an app bundle directly in Finder
cannot execute cleanup code; users who require complete removal must invoke this action first.
Historical tasks and files from the former `~/VoiceAssistant` workspace are included only when two
independent app-generated marker files prove ownership; the directory name alone is never authority
to delete data.

## Consequences

- macOS owns encryption, login lock-state enforcement, and key lifecycle. Device-only access-group
  enforcement additionally requires a provisioned production signature.
- The app knows why and where a credential belongs without exposing its value to Codex or SQLite.
- Listing requires Keychain access because unverified metadata is not displayed as authoritative;
  a locked Keychain therefore blocks vault listing as well as secret resolution.
- Reinstallation cannot silently recover credentials after the explicit data-delete action.
- Same-user file-only tampering is detected while the app-private Keychain value remains protected.
  Full account/process compromise and intentionally hostile bound executables remain outside the
  broker's protection boundary; only reviewed tools and recipes should receive credentials.
