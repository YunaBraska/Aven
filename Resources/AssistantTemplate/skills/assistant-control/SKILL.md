---
name: assistant-control
description: Control the voice assistant through its documented executable interface when the user asks to change app behavior, open assistant locations, present a result, or change an app capability.
---

# Assistant controls

Use the executable in `$VOICE_ASSISTANT_EXECUTABLE`; do not assume an installation path. Check
`"$VOICE_ASSISTANT_EXECUTABLE" assistant-control --help` before using a command. The app owns intent
recognition and exposes these language-neutral operations:

- `assistant-control progress on|off`
- `assistant-control speech pause|resume|stop`
- `assistant-control work stop`
- `assistant-control answer repeat`
- `assistant-control context clear`
- `assistant-control chat open`
- `assistant-control usage open`
- `assistant-control reveal context|agents|memory|database|recipes|vault`
- `assistant-control result set <absolute-path>`
- `assistant-control result show`
- `assistant-control launch-at-login on|off`
- `assistant-control capability <name> on|off`
- `assistant-control shortcut fn|right-option|right-control`
- `assistant-control shortcut status`
- `assistant-control access full-access|ask-for-approval|approve-for-me|custom`
- `assistant-control access status`
- `assistant-control diagram open <absolute-drawio-path>`

For an explicit request to open this chat or the current conversation, run `chat open` directly in
any language. Do not search the workspace, database, or memory for the command and do not claim that
the control is missing before checking this interface. The app opens Codex Desktop when it is
installed and compatible with the current thread; otherwise it opens the local transcript.

Invoke only the operation that matches the user's explicit request. Do not implement keyword matching
or infer controls from an ordinary sentence. If the executable or operation is unavailable, report that
clearly and continue the conversation without pretending it worked.

Stopping work cancels the active task and is reversible only by starting a new request. Do not use it
as a substitute for deleting data or changing permissions. Never run a control command through a shell
interpreter or concatenate user text into command syntax.

After completing a task that created or materially changed a file or project, register the narrowest
useful result path with `result set`. Do not open Finder automatically. Use `result show` only when the
user asked to see or open the result. The persistent menu row is the quiet default presentation.

Capability names are the raw names reported in the current capability summary. Enabling a protected
capability may trigger the app or macOS consent UI. Never claim that a capability was enabled until the
command succeeds and the following app state confirms it. Data deletion remains deliberately guarded
by native UI and is not exposed as a voice command.

After changing the shortcut or access profile, wait briefly and query its `status` command before
reporting success; retry for at most two seconds because notification delivery is asynchronous.
An access notification may be rejected when the installed Codex interface cannot implement the
requested profile; in that case the prior profile remains selected.
