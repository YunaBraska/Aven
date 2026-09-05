# ADR 0003: Dynamic Codex discovery, routing, and forwarding consent

## Status

Accepted

## Context

Codex model names, supported reasoning efforts, defaults, installation paths, and session state can
change independently of the menu-bar app. Keyword routing cannot interpret context-dependent turns
such as “do that”. Sending speech and files to an external AI service also needs an explicit boundary
separate from macOS microphone authorization.

## Decision

- Let the installer persist `command -v codex`, with configuration and `PATH` as fallbacks. Resolve
  symlinks and require safe file permissions before execution. Report an unverifiable Developer ID
  signature as a non-blocking warning.
- Read the visible account model catalog and effort options from the installed Codex app server.
- Follow the app-server handshake strictly: wait for the initialize response before sending
  `initialized` and `model/list`.
- Run private app-server helpers with extension features disabled, a reduced environment, no
  notification command or telemetry exporters, and the built-in OpenAI provider pinned to the
  trusted endpoint matching `codex login status`. Unknown authentication modes fail closed.
- Select a model and effort with a read-only, ephemeral semantic routing turn. Fork the current
  conversation when it exists, validate the returned identifiers against the live catalog, and
  otherwise fall back to Codex's current default.
- Send queued input directly to the active turn through Codex steering. Re-evaluate model and effort
  at the next task boundary; do not add the latency of a second routing turn to steering.
- Keep multi-agent delegation available rather than coupling it to one model identifier.
- Require versioned, default-off consent immediately before every Codex process boundary. Revocation
  cancels active work and prevents capture or transmission.
- Classify missing executable, login, expired session, network, rate limit, unavailable model,
  unavailable required function, and local access failures into distinct user messages. Degrade by
  discovered function; do not compare hard-coded version numbers.
- Do not App-Sandbox the local ad-hoc build: it must launch the separately installed CLI and honor
  user-requested work across local files. Keep the hardened runtime; rely on request scope and the
  assistant's confirmation rules rather than a filesystem allowlist.

## Consequences

- New catalog entries and effort values require no app release.
- Routing understands rolling context and does not depend on language-specific keywords.
- Automatic routing adds one small model turn; its process is cancellable and cannot write.
- User configuration cannot redirect helper traffic to a custom provider or notification command.
- A spoken request cannot leave the Mac until the user accepts the disclosure.
- App Store distribution would require a different brokered architecture or an entitlement review.
