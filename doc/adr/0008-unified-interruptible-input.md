# ADR 0008: Unified interruptible input

## Status

Accepted

## Context

Speech, file drops, and automation messages can arrive before a Codex task has started, during an
active turn, while the result is being spoken, or while context maintenance is running. Treating
each source independently lost ordering and encouraged repeated steering attempts.

## Decision

All user input enters one FIFO conversation queue. Input received before the active task identifier
exists waits there. Once a task is steerable, queued input is combined in order and submitted once
through Codex steering. A rejected steering request is restored to the head of the queue and retried
only after the active turn ends; there is no polling or retry loop. Input received during speech or
maintenance starts the next turn when that activity reaches a safe boundary.

File drops use the same path as speech and App Intents. The transient drop panel remains a valid
drag destination and has a short delayed close to bridge the physical gap below the menu bar.

## Consequences

- Inputs preserve their arrival order across every source.
- Steering avoids a second model-routing request.
- A broken or temporarily unavailable steering function cannot block Aven or create retry traffic.
- Stop clears queued input and pending attachments together.
