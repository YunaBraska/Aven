# ADR 0012: On-demand foreground context broker

## Status

Accepted

## Context

A user may refer to text selected in the foreground app or text they intentionally copied. Codex
needs that value only for the related request. Continuous clipboard or accessibility observation
would collect unrelated information and create ambiguous context. MCP would also add a general tool
server where two narrow local reads are sufficient.

## Decision

Aven exposes fixed `assistant-context selection` and `assistant-context clipboard` operations on
its existing executable. They are available only to a Codex child that holds a context token issued
for the current app process and validated against one exactly named, app-owned Keychain item. The
token is replaced at launch and removed at orderly termination. Each operation also honors its Aven
capability toggle, returns at most 256 KiB of valid UTF-8, and performs one read per invocation.

Selected text uses the macOS Accessibility API. Clipboard text uses the general pasteboard and lets
macOS apply its pasteboard privacy behavior. A bundled skill selects the operation semantically when
the current request refers to selected, highlighted, marked, copied, or clipboard content. No user
phrase is compiled into the app.

Captured text is untrusted request context. It is not watched, cached, or written to assistant
memory unless the user separately asks to remember it. A failed selection read does not fall back
to the clipboard because copied text may be stale and unrelated.

## Consequences

- Saying the equivalent of “I marked something” can cause a one-shot selection read.
- Aven, not Codex itself, owns the macOS permission and the bounded OS API call.
- The broker is not MCP; the Codex App Server remains the conversation transport while this helper
  is a local capability boundary.
- Accessibility denial affects only selected-text context. The rest of Aven remains usable.
