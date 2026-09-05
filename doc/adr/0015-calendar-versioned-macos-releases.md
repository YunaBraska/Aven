# ADR 0015: Calendar-versioned macOS releases

## Status

Accepted

## Context

Aven needs the same repeatable build and release path as the other YunaBraska Swift applications.
Local builds must remain useful without Apple signing credentials, while public artifacts should use
Developer ID signing and notarization whenever those credentials are configured.

## Decision

- Reuse the pinned YunaBraska Swift CI and release workflows used by Sentrio and PearchHA.
- Release versions use the UTC calendar form `YYYY.M.D`; merge builds use the shared snapshot form.
- Feed the resolved version into both bundle version fields at build time instead of modifying the
  tracked property list.
- Produce a universal `Aven.app`, `Aven-<version>.zip`, and `Aven-<version>.dmg`.
- Ad-hoc signing remains valid for local and uncredentialed CI builds. Configured Developer ID and
  notarization credentials upgrade the same package path without changing its structure.
- The local installer verifies, stages, and launches only `/Applications/Aven.app`.

## Consequences

- Repository builds and releases follow the same controls and version cadence as peer applications.
- A release created without signing secrets is suitable for testing but will still trigger normal
  Gatekeeper warnings; CI does not pretend otherwise.
- Release creation remains an explicit workflow action and does not create tags during local builds.
