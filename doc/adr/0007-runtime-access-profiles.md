# ADR 0007: Runtime Codex access profiles

## Status

Accepted

## Context

Aven needs unrestricted local work for explicitly requested tasks, while some users prefer a
sandbox, automatic review, or their own Codex configuration. New and resumed `codex exec` commands
do not expose identical shorthand flags. A menu option must describe real process behavior rather
than imply an approval UI that Aven cannot service.

## Decision

- Persist one of Full Access, Ask for Approval, Approve for Me, or Custom.
- Discover the installed non-interactive command capabilities from `codex exec resume --help` in the
  background. Unsupported profiles remain visible but disabled with a reason.
- Express managed profiles through `--config` overrides accepted by both new and resumed tasks.
- Full Access uses `danger-full-access` with approval policy `never`.
- Approve for Me uses `workspace-write`, approval policy `on-request`, and Codex's automatic
  reviewer.
- Ask for Approval is enabled only when the installed command advertises a usable interactive
  approval option. Aven does not emulate authorization with a conversational promise.
- Custom applies no access or extension-isolation overrides and honors the user's `config.toml`,
  including MCP servers and plugins.
- Apply a changed profile at the next idle task boundary. Never interrupt an active response.

## Consequences

- The menu reflects actual subprocess authority.
- Managed profiles keep optional MCP/plugin startup cost and authority out of ordinary voice turns.
- Custom mode can be slower or broader because that is the user's explicit Codex configuration.
- A full native approval experience requires moving execution to an interface that exposes
  approval requests and responses; it is not faked in the current CLI runner.
