# Which AI command does the assistant run?

The app discovers `codex` from the installer-stored `command -v` result,
`VOICE_ASSISTANT_CODEX_EXECUTABLE`, or `PATH`. It starts the resolved executable directly, sends the spoken request over standard input,
and reads Codex JSONL events from standard output. It does not build a shell command string.

When Homebrew is available, background maintenance owns only the `codex` Cask. It runs exact argument
arrays for weekly metadata refresh, Cask inspection, installation, and upgrade; the child environment
excludes app-control and credential values. The latest successfully installed Cask is selected. A
separately installed Codex is not deleted. Signature and capability probes report warnings only and
there is no version pin or rollback path.

Before a request, `codex app-server --stdio` supplies the current account's visible models and
supported reasoning efforts when the six-hour in-memory catalog cache is cold. A read-only
ephemeral `codex exec` routing turn, or `exec fork` when
conversation context exists, returns identifiers that are validated against that catalog.

The routing turn prefers a live text-only model at its lowest advertised effort. This minimizes
unneeded modality and reasoning work, but does not claim that text-only always means cheapest: the
catalog currently exposes no stable price or model-size ordering field. The routing result itself
selects the least expensive and fastest model that can reliably handle the actual request.

The effective shape is:

```text
codex exec [or: exec resume] [--model <routed-model>] --json [--search] \
  --config sandbox_mode=\"danger-full-access\" \
  --config approval_policy=\"never\" \
  --cd '<Application Support assistant workspace>' -
```

Optional feature names are taken from `codex features list`; Aven disables only advertised plugins,
hooks, and high-authority UI/computer-control features. A failed feature probe removes only those
optional flags, not the request. The private app-server helpers never start a user turn or call tools and explicitly
neutralize notification commands, custom model-provider selection, and OpenTelemetry exporters.
The exact argument construction lives in `Sources/CodexClient.swift`.
Secret material is available only through the installed fixed-argument broker, backed by the app's
private macOS Keychain service. Each turn receives a random, expiring capability whose authoritative
grant is looked up in that service, bound to the issuing Aven process ancestry, and revoked when the
turn ends. The value is transport, not a self-contained permission. Broker or Keychain failure
leaves ordinary Codex work running. Native Codex web search is enabled only while the app's `Web
Search` capability is enabled.

Selected foreground text and clipboard text use the fixed-argument `assistant-context` broker. It
requires the same expiring, process-bound task capability as the other privileged commands, honors
the corresponding Aven permission, and returns one bounded value. The grant is revoked when the
turn ends. It is not MCP: no discoverable general-purpose local tool server is needed for these two
macOS reads.

An explicitly confirmed meeting mode uses ScreenCaptureKit to receive system audio and, on macOS 15
or newer, microphone audio. Aven excludes its own speech output and sends both streams only to the
system's on-device Speech recognizer. Finalized timestamped segments are flushed to a private JSONL
file under `$VOICE_ASSISTANT_HOME/meetings`; raw audio is never written. The active transcript path
is exposed to the current Codex task only when the request concerns that meeting. Meeting capture
continues independently of ordinary questions and has a persistent click-to-stop menu control.

New spoken input is persisted to an app-private delivery journal before it enters the phase-aware
FIFO queue together with any attachments. During routing
it waits until the process publishes an active task identifier; while a request is running it uses
`codex queue --thread <active-thread> --message <instruction>`. During response
or speech it waits for the next task boundary. This steers the existing task when possible and does
not discard input merely because Codex has not started yet. Successful turn completion or accepted
steering acknowledges and removes the journal entry; failed or interrupted delivery is recovered
after restart. The current
capability summary is included with each request. Calendar reads go through the app executable's
bounded `calendar list` broker. Mail is not advertised because the app does not yet have a real
Mail broker or connector.

Multiple steering inputs are supported. They retain arrival order; accepted input is owned by the
active task, and any following queued input is submitted when Codex can accept it. “No second
routing pass” means model selection is not repeated for those additions, not that steering is
limited to one message.

Optional catalog and routing functions fail independently: their absence leaves Codex's own default
selection in place without an inaccurate warning. The app does not compare CLI version numbers.
There is likewise no Codex-to-ChatGPT Desktop version matrix. Login status and the account-visible
model catalog come from the installed Codex client; command and app-server capabilities are probed
directly. Missing resume, steering, or model discovery affects that feature rather than disabling
otherwise compatible conversations.

When `CODEX_HOME` is an absolute path, routing, compaction, session metrics, transcript discovery,
and Terminal resume use that same Codex store. Relative values are ignored rather than resolving
them differently across background processes.

Each clearly named durable project may have its own thread. The semantic router selects the current,
an existing, or a validated new context key; inactive mappings expire after 90 days without deleting
Codex history. When the active thread reaches 75 percent context use and remains idle for ten minutes,
the app uses `thread/resume` followed by `thread/compact/start` on a private stdio app-server process.
It negotiates the experimental `excludeTurns` field so resuming an already-large thread does not
first return every historical turn to the menu-bar process.

`Open Chat` prefers the Desktop deep link. If it is unavailable, a validated UUID-backed task opens
in visible Terminal through `codex resume <thread-id> --cd <workspace>`; the local transcript is the
last fallback.

Managed access profiles use config overrides accepted by both new and resumed non-interactive
turns. Full Access selects unrestricted local access with no approval pause. Approve for Me selects
workspace-write, on-request approval, and Codex's automatic reviewer. Ask for Approval is enabled
only when the installed non-interactive interface advertises a usable approval boundary. Custom
passes neither isolation nor access overrides and therefore honors the user's `config.toml`,
including configured MCP servers and plugins.

## Why isn't the command an arbitrary text field?

A free-form shell template would turn a typo or malicious memory entry into command execution.
The app deliberately supports only Codex. A backend adapter would require:

- executable discovery and a fixed argument-array protocol;
- its own authentication managed by that CLI;
- an explicit read/write permission policy;
- an output parser for that backend;
- cancellation, timeout, and error translation;
- tests using the public request entrypoint.

Other CLIs have different output formats, permission models, and conversation identifiers.
Changing only one command string would therefore be unreliable and is outside the app's scope.
