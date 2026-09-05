# ADR 0010: Bounded session metrics

## Status

Accepted

## Context

Codex session history can reach gigabytes. Loading every session file into memory merely to show a
weekly allowance or current context count caused Aven's startup footprint to peak above six
gigabytes on an established account.

## Decision

Aven reads only the final two megabytes of a session when looking for recent token and rate-limit
events. It considers at most the twelve most recently modified sessions for the historical weekly
fallback. Once the dedicated account-metrics cache has a current value, those twelve fallback tails
are not read. The first event of each session remains bounded to 64 KB and identifies the active
task and descendant-worker relationship. The first partial line in a bounded tail is discarded.
The dedicated account-metrics cache remains the authoritative current source when available.
Successfully parsed session headers are indexed in memory by their standardized UUID-backed path
for the lifetime of the app. Each directory scan updates modification dates and removes paths that
no longer exist, while incomplete or malformed headers are never cached. The index therefore avoids
reopening every old session on repeated menu refreshes without mixing runtime relationships into
the durable assistant database or serving them from an arbitrary TTL.

## Consequences

- Menu metrics remain independent of total historical session size.
- Recent token events remain visible because Codex writes them near the end of a session.
- Current account data avoids the historical weekly-tail fallback entirely.
- Repeated menu refreshes enumerate current paths but do not reread immutable headers.
- Very old rate-limit events are intentionally ignored; a missing fallback displays an explicit
  dash until the current account-metrics refresh completes.
