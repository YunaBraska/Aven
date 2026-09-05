# ADR 0014: Durable input delivery and single-instance ownership

## Status

Accepted

## Context

Speech, typed text, and dropped files previously entered only an in-memory phase queue. Starting a
turn removed its input before routing or Codex had succeeded. A route failure, application crash,
or competing build copy could therefore make a user message appear to vanish. Concurrent Aven
processes could also compete for one status item, task context, and app-scoped storage.

## Decision

- Persist each accepted input atomically in the app-private Application Support directory before
  it enters routing.
- Give each persisted input an opaque delivery identifier and preserve those identifiers when
  several messages are combined for steering.
- Acknowledge and remove an input only after a completed Codex turn or successful steering command.
- Requeue a failed active turn in memory and reload every unacknowledged entry on the next launch.
- Keep entries until acknowledgement; only explicit Stop and Delete Assistant Data discard them.
  Quit, permission changes, infrastructure cancellation, and Clear Context retain accepted input.
- Quarantine a malformed journal before accepting new input. If quarantine or persistence fails,
  reject the new input visibly and leave typed text in place rather than overwriting unknown data.
- Snapshot accepted attachments into a private copy-on-write spool, keep the journal array as the
  canonical FIFO order, and remove snapshots only after acknowledgement or explicit discard.
- Bound each message, attachment count, per-file and aggregate attachment size, and total
  pending-entry count before the atomic write.
- Hold a per-user advisory process lock for the full GUI lifetime. Command-mode broker invocations
  remain available while the GUI owns the lock.
- If optional semantic routing fails, omit model and effort arguments entirely so the current Codex
  CLI default handles the request.

## Consequences

- Delivery is at-least-once across an abrupt crash. A crash after Codex completed but before the
  local acknowledgement can replay a request; this is preferable to silent loss.
- The journal contains user text and paths to private attachment snapshots. Both use user-only
  permissions and are deleted with all other assistant data.
- Build and installed copies share one lock and cannot produce duplicate menu icons or contend for
  the same conversation.
