# ADR 0006: Project context lifecycle

## Status

Accepted

## Context

One permanent conversation makes unrelated projects contaminate each other and consumes the model
context window unnecessarily. Deleting history would lose useful continuity. Codex app-server
already exposes native context compaction, while each Codex thread remains independently resumable.

## Decision

- Keep a general context and create a separate Codex thread only for a clearly named, durable
  project. Ordinary conversation, brainstorming, one-off work, and ambiguous follow-ups stay in the
  currently active context.
- Let the semantic router choose among known project keys or propose `new:<slug>`; do not use keyword
  matching. Validate and normalize the returned key before persistence.
- Expire a project-to-thread mapping after 90 days without use. Expiry removes only the mapping; it
  does not delete the Codex thread, assistant memory, decisions, or task artifacts.
- After a completed conversation, wait ten minutes. If the active context is at least 75 percent
  full and the assistant remains idle, call `thread/compact/start` once for that idle generation.
- New speech never waits for maintenance: it is transcribed and queued while an active compaction
  finishes. Explicit Stop, Clear Context, or app termination cancels maintenance. Compaction
  failures become warnings and never block conversation.

## Consequences

- Context-dependent phrases remain meaningful inside the active project.
- Project histories grow independently and inactive mappings disappear without destructive cleanup.
- Native compaction preserves continuity while reducing pressure on the active model window.
- Routing and maintenance remain silent unless a real failure affects the user.

## Verification

- Legacy single-thread state migrates to the general context.
- Independent project keys restore their own thread IDs.
- Stale mappings expire without deleting the underlying thread identifier from Codex storage.
- Compaction requires a valid thread, ten minutes idle, and at least 75 percent context use.
- The app-server flow resumes the thread and waits for the real compaction-completed event.
