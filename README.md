# Aven

[![CI](https://github.com/YunaBraska/Aven/actions/workflows/build-merge.yml/badge.svg)](https://github.com/YunaBraska/Aven/actions/workflows/build-merge.yml)
[![Release](https://img.shields.io/github/v/release/YunaBraska/Aven)](https://github.com/YunaBraska/Aven/releases)
[![License](https://img.shields.io/github/license/YunaBraska/Aven)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://support.apple.com/macos)

Aven is a quiet macOS menu-bar companion for spoken work with Codex. Hold one key, speak, release
it, and hear the answer. There is no permanent window, wake word, or always-listening microphone.

Aven is more than dictation into a chat. It keeps a continuing conversation, understands the active
project, remembers useful decisions and preferences, can work with local files, and turns Codex's
progress into short spoken updates while you remain in the application you were already using.

## Everyday use

- Hold the selected talk key, speak, then release it.
- Speak again while Codex is starting or working. Aven keeps the input and steers the active task as
  soon as Codex can accept it.
- Use the mnemonic chords shown in the menu to repeat, pause or resume speech, and stop everything.
- Type into `Message Aven` and press Return. Typed text uses the same ordered
  start/steer queue as speech and dropped files.
- Drop files on Aven's menu-bar icon. A small target appears below the icon and the files become part
  of the current request through the same queue as speech. The target stays open while the drag
  crosses from the menu-bar icon into it.
- Open `Sources (N)` to see one recent list of files and web pages, each with its own icon. Files reveal
  in Finder; links open in the default browser. Stored links omit query strings and fragments so
  tokens and signed parameters cannot become durable history; query-defined pages reopen at their
  safe base path.
- Open `Show Result` when a task produced a file worth presenting. Aven does not open Finder merely
  to celebrate moving a comma.
- Choose `Record Meeting…` and confirm only after informing the participants. Aven transcribes the
  system audio and, on macOS 15 or newer, the microphone on device without retaining raw audio.
  While capture is active the same row becomes `Stop Meeting Recording`, the menu-bar face gains a
  recording dot, and ordinary questions still use the normal conversation queue.

The default talk key is `Fn`. Under `Options → Shortcuts`, recommended choices are available and
`Record Talk Key…` accepts any supported physical left/right modifier. Recording has a visible
Cancel button and leaves the previous shortcut unchanged when cancelled. The matching mnemonic
chords are shown directly in the menu.

The same settings can be changed by speaking to Aven. Shortcut and access changes use a narrow
language-neutral control interface and are read back before Aven reports success; ordinary phrases
such as “do that” are never hard-coded as control commands.

## Conversation without losing focus

Aven queues input according to the real conversation phase:

1. Before Codex has started, additional speech waits for the active task identifier.
2. During an active turn, it is sent as steering rather than becoming another conversation.
3. During response or speech output, it waits and begins the next turn afterward.
4. Stop clears pending input together with active recording, Codex work, and speech.

Every accepted message is written to an app-private delivery journal before routing begins. It is
removed only after Codex completes the turn or accepts the steering update. A crash, failed route,
or restart therefore recovers the message in FIFO order instead of silently losing it. Aven also
holds a per-user process lock, so build and installed copies cannot run concurrently.

Progress messages describe visible work such as inspecting a folder or running checks. They are
ordered with the final answer, never spoken over one another, and never expose private
chain-of-thought. `Speak Progress` turns those updates on or off.

The system language, Read & Speak voice, and default sound output are used automatically. Every
utterance resolves them again, so switching speakers, headphones, or voice does not require an app
restart. `Options → Voice` shows the current selection and opens the matching macOS settings page. A bundled spoken-clarity skill
instructs Codex to summarize technical notation, markup, tables, diffs, and URLs for speech; the
final renderer also removes common Markdown decoration and link destinations.

## Memory and projects

Aven keeps durable facts, decisions, corrections, commitments, reusable work rules, and its own
developing identity in a local SQLite database. Brainstorming remains tentative and can expire; it
does not silently become a permanent decision. Secrets and full transcripts never belong in this
memory.

Memory lookup is quiet. Aven does not announce database work before answering a question about its
name or prior context. It starts without a fixed personality, chooses a neutral name only when first
asked, and can develop its own character through conversation. Observable answer preferences are
kept separately from personality; there is no covert psychological profile of the user.

Clearly named, durable projects can receive independent Codex contexts. Ordinary conversation,
one-off work, brainstorming, and ambiguous follow-ups remain in the current context. An unused
project mapping expires after 90 days without deleting the underlying Codex task. A context that is
at least 75% full is compacted once after ten quiet minutes. Speech received during compaction is
queued; Aven remains usable.

`Options → Clear Context` starts a fresh Codex task. It does not delete memory, projects,
credentials, or old Codex history.

## Skills

Aven ships its skills inside the app, so a new user receives the same useful starting set. Skills
load only when their description matches the task. They cover:

- memory curation, safe credentials, repeatable task recipes, review, and editable diagrams;
- Playwright-compatible browser testing through observable user behavior;
- Git, authenticated and pragmatic REST APIs, current web research, and artifact inspection;
- macOS preferences, application lifecycle, automation, operations, and observability;
- modern Java, Kotlin, Go, Swift, and Rust work plus native, accessible UI/UX;
- natural voice small talk, interruptible voice-only games, consent-aware meeting transcript notes,
  on-demand selected or copied text, and clear spoken rendering of technical content.

Stable repeated work may become a parameterized POSIX shell recipe after an explicit request or two
successful repetitions. Unused recipes expire instead of accumulating forever. Authenticated API
work prefers a suitable direct REST interface when a matching scoped credential exists; for
example, a Jira REST credential takes precedence over adding a Jira MCP dependency.

## Menu and status

The menu is arranged by intent: current status and warnings, conversation controls, chat/results/
sources, live metrics, local assistant data, options/access/permissions, then About and Quit.
There is no idle `Ready` row.

The menu-bar icon is composed from native macOS symbols: the main activity state remains readable
while recording and warning badges can coexist. It uses calm,
non-blinking motion for listening, transcription, routing, Codex work, compaction, and speech. A
recording dot remains visible throughout meeting capture; a warning mark appears only for a real
actionable warning. Reduced Motion is respected.

Warnings and their text appear directly at the top of the main menu. Persistent conditions remain
until resolved; transient runtime failures expire after ten minutes. Storage details, the last
stage timings, and the Codex version remain together under `More…` so ordinary menu rows never move
according to activity.

`Timing · Last` is a non-interactive heading inside `More…`; its stage rows appear directly below
it instead of opening another submenu. They show the most recent pipeline pass, not a sum or an
average, and cause no network request. Account usage is cached and refreshed in the
background; menu painting never waits for the network. The weekly allowance is shown as remaining,
is clickable, and opens the Codex usage page.

## Access and privacy

`Access` controls how the Codex subprocess is launched:

- `Full Access` gives the explicitly requested task unrestricted local access without a folder
  allowlist and does not pause for approvals.
- `Ask for Approval` is shown only when the installed non-interactive Codex interface can actually
  support it; Aven does not offer a decorative safety switch.
- `Approve for Me` uses Codex's automatic approval reviewer in a workspace-write sandbox.
- `Custom / config.toml` leaves sandbox, approval, MCP, plugin, and other Codex configuration to the
  user's own file.

Changing access affects the next safe task boundary and never stops an active answer. Normal Aven
profiles isolate optional Codex plugins, MCP configuration, hooks, computer control, and similar
extensions. Custom mode deliberately restores the user's Codex configuration.

`Permissions` lists the capabilities Aven itself owns directly, with stable separator-delimited
groups instead of nested menus. They include microphone, on-device transcription, shortcut monitoring,
one-shot selected text or clipboard access, screen and meeting-audio capture, calendar, web
research, and forwarding to OpenAI.
macOS permission prompts appear when a requested feature first needs them. Screen capture happens
only when the spoken request explicitly refers to the screen, and its temporary image is removed
afterward. Selected and clipboard text are never polled; a semantically matching request triggers a
single bounded read through Aven's local broker.

Credentials are stored under one app-owned macOS Keychain service; Aven never enumerates the user's
other passwords. Non-secret purpose, source, scope, and expiry metadata remains in Application
Support. Every Codex turn receives a short-lived capability which is revoked at completion and is
valid only inside that turn's descendant process tree. A locked Keychain or unavailable broker
blocks only the credential-dependent operation. Browser sessions expire.
Updates reuse the same vault and data locations. `Delete Assistant Data…` requires confirmation and
removes Aven's Keychain items, local workspace, stored task ownership, and preferences together.

## Install

Download the latest ZIP or DMG from [GitHub Releases](https://github.com/YunaBraska/Aven/releases),
then place `Aven.app` in `/Applications`.

To build, install, and launch the current source checkout, run:

```sh
./install.sh
```

The installer verifies the complete bundle before replacing an existing installation. It launches
only `/Applications/Aven.app`; build output is never launched in place.

Aven requires macOS and an authenticated Codex CLI. If Homebrew exists, Aven installs the latest
Codex Cask when missing and checks weekly while idle. It does not install Homebrew, use `sudo`, pin
or roll back Codex, or update unrelated packages. A missing Developer ID signature is a warning,
not a blocker. Login remains an explicit `codex login` action because it can select an account and
open a browser.

`Open Chat` prefers Codex Desktop when the task format is compatible, then opens a visible Terminal
resume, and finally falls back to the local transcript. The Terminal handoff suppresses Codex's
startup update prompt because Aven already owns the weekly update check. It otherwise behaves like
an intentional interactive Codex session. Duplicate requests within two seconds are coalesced.

Aven also publishes native App Intents for sending text into the same start/steer queue and for
listening, stopping, pausing, repeating, opening chat or usage, showing a result, clearing context,
and enabling or disabling spoken progress. This makes the controls available to Shortcuts without
duplicating Aven's state machine.

## Development

Aven is an AppKit accessory application built with the checked-in Xcode project and no runtime
package manager. `build.sh` compiles, generates App-Intent metadata, tests, creates the Retina icon
set, applies the hardened runtime, and ad-hoc signs the app.

```sh
./test.sh
./build.sh
./install.sh
sh scripts/package.sh 0.0.1
```

The installed assistant workspace is:

```text
~/Library/Application Support/Aven/Assistant
```

App-managed rules are updated only when their bundled contents changed. Bundled skills are
discovered from the app and synchronized incrementally into Codex's native `.agents/skills`
workspace. New bundled skills therefore need no Swift registry change; user-created skills remain
untouched. User memory, project mappings, recipes, and credentials remain user-owned. Codex is located dynamically through installer state, explicit
configuration, `PATH`, and macOS path discovery; no Homebrew prefix or model name is compiled in.
The live account model catalog is cached in memory for six hours. A semantic routing pass selects a
model, effort, and project context without language-specific keyword rules. Its planner is chosen
from the live catalog by structured capability, preferring an available text-only model at its
lowest advertised effort because the route request has no image input. The catalog does not expose
a stable cost or model-size rank, so Aven does not invent one. When a semantic routing pass does not complete within three
seconds, Codex's current default handles that request. After any slow routing pass, three turns use
that live default immediately before semantic routing is probed again. A route is never reused blindly for a
different prompt. Steering never starts a second routing pass. A failed optional routing pass is
quietly omitted; Aven passes no model or effort override and lets the live Codex CLI select its
current default. Only a failure of that actual request becomes a warning.

Model, skill, memory, instruction, and capability selection remain internal. Aven begins with the
answer or a concrete useful progress update instead of announcing that it is an assistant or that it
is looking for something suitable for voice or a screen-free interaction.

Normal turns use fixed argument arrays and bounded JSONL over standard I/O, not shell command
strings. Optional Codex feature flags are discovered from the installed executable and cached;
removed or renamed flags are omitted instead of breaking the main turn. The app ignores user Codex
configuration for its managed access profiles and disables available extensions that would add
startup cost or authority. `Custom / config.toml` intentionally opts back into them.
Account data has a 15-minute minimum refresh interval and local menu metrics have a 30-second
minimum refresh interval; these are throttles, not promises to poll. Refreshes happen less often
when idle and concurrent refreshes coalesce.

To locate the current context and calculate descendant-worker storage, the local metrics loader
reads only the first event of Codex session files and keeps successfully parsed immutable headers in
a process-lifetime index. Removed paths are pruned and incomplete headers are retried; no arbitrary
TTL or durable-memory table is involved. It reads a bounded tail from the active session
for context usage. At startup, up to twelve recent tails may provide a weekly-usage fallback; once
the dedicated account cache has current data, that fallback scan is skipped.

See [verified behavior](doc/test-map.md), [how instructions are assembled](doc/instructions.md),
[the Codex boundary](doc/backends.md), and the records under [`doc/adr`](doc/adr). The local build is
intentionally not App-Sandboxed because it launches a separately installed CLI and performs
user-requested work across local files. Local packages are ad-hoc signed. Release CI uses Developer
ID signing and notarization only when its credentials are configured; App Store distribution is not
claimed.
