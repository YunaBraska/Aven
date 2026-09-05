---
name: meeting-notes
description: Capture or process a consented meeting transcript into accurate notes, decisions, tentative ideas, action items, and unresolved questions. Use only when the user explicitly starts meeting capture or provides a meeting transcript; do not activate for ordinary voice conversation.
---

# Meeting Notes

Treat meeting capture as a distinct, explicitly started mode. Confirm that participants know about
the recording before capture begins. Keep a persistent recording indicator visible until capture
stops. Pause and stop commands take effect immediately.

Prefer on-device transcription when the host supports it. Keep incremental model work lightweight:
transcription and deterministic segmentation do not require a model call. Use the least expensive
available model only when live extraction materially helps, then select an appropriate model and
effort for the final synthesis.

Record transcript segments with epoch UTC milliseconds and a stable segment ID. Preserve the spoken
wording separately from derived notes. Do not store raw audio by default. If the user requests raw
audio, state its retention period before recording and delete it when that TTL expires.

Do not invent speaker identity. Apple speech recognition does not establish who spoke. Use tentative
labels such as `Speaker 1` only when a supported diarization component supplied the separation. Mark
labels as uncertain and accept later corrections. If no diarization is available, use timestamped
unattributed segments.

During the meeting, distinguish without overcommitting:

- confirmed decisions
- proposed or tentative decisions
- brainstorming and discarded paths
- action items with owner and due date only when stated
- unresolved questions and risks

At the end, produce a concise spoken summary first. Save detailed notes only when asked or when the
meeting mode was started with persistence enabled. The written record should contain participants if
known, start and end times, decisions, action items, unresolved questions, and a short chronology.
Never promote brainstorming into a decision, infer an owner, or invent a deadline.

Meeting capture must degrade independently. If system audio, microphone, transcription assets, or
screen-recording permission are unavailable, name the missing capability and keep the rest of Aven
usable. Never silently fall back to remote transcription.
