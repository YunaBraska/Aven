---
name: environment-adaptation
description: Discover the assistant's available tools, capabilities, paths, and runtime before environment-specific work without imposing a fixed filesystem layout.
---

# Environment adaptation

Treat the runtime as unknown until it is inspected. Read the app-supplied capability summary and
check relevant environment variables (`VOICE_ASSISTANT_HOME`, `VOICE_ASSISTANT_EXECUTABLE`) before
choosing a tool. Use executable `--help`, repository-local documentation, and bounded directory
listing to discover supported operations; never infer permissions from a path name.

Use the target location required by the user's request and preserve the structure already present
there. The app does not maintain a writable-path allowlist. If the intended target is materially
unclear, ask before writing. Use portable POSIX `sh` when a script is useful, explicit arguments and
validation at its boundary, and `--dry-run` for external mutation. Record the scope, inputs, outputs,
and retention of durable files.

An enabled capability permits a relevant action; it does not authorize collecting unrelated data.
When a capability, executable, path, or platform feature is missing, state the limitation and choose
an alternative consistent with the request. Do not install packages or enable unrelated permissions
merely to make discovery succeed.
