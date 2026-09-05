# ADR 0013: Live meeting transcript as a separate capture mode

## Status

Accepted

## Context

Meeting capture must continuously hear meeting audio while Aven still accepts questions and
steering. Starting a second independent microphone recorder would compete with hold-to-talk,
duplicate transcription resources, and make pause and failure behavior unpredictable.

## Decision

Meeting capture will be an explicit, independently stoppable mode owned by one audio coordinator.
On supported systems it will use ScreenCaptureKit outputs for chosen system audio and microphone
audio, exclude Aven's own speech, and feed on-device speech analysis. Older supported macOS versions
will use feature-detected fallbacks rather than remote transcription.

Finalized transcript segments will append to:

```text
$VOICE_ASSISTANT_HOME/meetings/<meeting-id>/live.jsonl
```

Each line will contain a stable segment ID, start and end in UTC epoch milliseconds, source,
language when known, text, and confidence when supplied. Partial hypotheses remain in memory and
are replaced rather than appended. Writes are serialized and flushed so an active Codex question
can read a bounded snapshot while capture continues. Raw audio is off by default and requires an
explicit retention period.

Holding the talk key during a meeting marks the user's request path; it must not start a competing
audio engine. Questions and file or text additions still enter the normal conversation FIFO and
steer the active task. Meeting capture status remains visible in the menu icon and menu until
stopped. Consent is explicit, and Aven reminds the user that they are responsible for informing
participants.

The final meeting-notes pass reads the transcript and distinguishes confirmed decisions, tentative
proposals, brainstorming, actions, and unresolved questions. Speaker identity is never inferred
from Apple transcription alone.

## Consequences

- Live notes are readable during capture without waiting for the meeting to finish.
- Capture, questions, Codex work, and speech output can fail or pause independently.
- The integrated coordinator keeps transcript writes private and durable, does not retain raw audio,
  and exposes start and stop through the menu, App Intents, and the assistant control command.
- Real-device interruption and permission-recovery checks remain release verification because TCC
  prompts and external meeting audio cannot be simulated faithfully in a unit test.
