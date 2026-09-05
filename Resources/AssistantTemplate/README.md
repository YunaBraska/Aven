# Assistant workspace

This is Aven's per-user assistant workspace.

- `AGENTS.md` defines stable operating boundaries.
- `database/assistant.sqlite3` stores structured memory and adaptive style signals.
- `.agents/skills/` contains app-supplied and user-owned capabilities discovered natively by Codex.
- `recipes/` contains expiring user-specific workflows.
- `decisions/` contains the portable assistant policy and durable decisions made in conversation.

Secret values belong only in the app-owned credential vault beside this workspace.
