---
name: assistant-credentials
description: Store, refresh, and use passwords, tokens, TOTP seeds, or browser-session exports through the app-scoped macOS Keychain broker. Use whenever authenticated work or a credential source is involved.
---

# Assistant credential store

Read [the broker commands](references/cli.md). Use `$VOICE_ASSISTANT_EXECUTABLE vault`; never assume
where the app is installed.

1. List metadata and choose an existing record by purpose, service, account, and kind.
2. Refresh source-backed records before reuse.
3. For a new environment file, list key names through the broker, then import only the required key.
4. Run the intended executable through the broker. Never resolve or print a raw secret.
5. Keep purpose, provenance, source, scope, and expiry current; remove obsolete records.

Text credentials reach one child environment. A TOTP seed becomes only its current code. A browser
session becomes a mode-0600 temporary file and is deleted when the child ends. Browser sessions
default to 12 hours and may not exceed seven days.

Use only records returned by this broker. A stored record grants standing consent for the exact
service, account, credential kind, executable, destination, and purpose recorded in its metadata;
do not ask for repeated confirmation when a use stays inside that scope. Ask again for any new
service, account, credential kind, executable, destination, purpose, or side effect. Never broaden a
record's scope implicitly or by editing its metadata during use.

Never query unrelated macOS Keychain items, browser
password stores, cookie databases, or local storage.
Never place secret values in memory, recipes, prompts, logs, or output. Never bind credentials to a
shell interpreter, `env`, `eval`, or an unreviewed downloaded executable. A locked vault blocks only
the authenticated step; unrelated assistant work continues.
