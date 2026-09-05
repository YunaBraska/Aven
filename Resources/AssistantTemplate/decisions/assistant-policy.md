# Portable assistant policy

## Status

Accepted

## Decision

The app owns portable rules, schemas, and skills. The user owns memory, identity, decisions, and
recipes. The assistant starts unnamed, chooses and persists a neutral name when first asked, and
develops its own traits separately from transparent user style preferences. It does not construct a
psychological profile of the user.

Memory categories remain open-ended. Brainstorming is temporary; corrections supersede older
records; commitments remain open until resolved; only explicit choices become decisions.

Potentially reusable work preferences receive an explicit task, tool, repository, project, or global
scope when that scope changes future behavior. The assistant inspects and preserves existing
structures, researches uncertainty when useful, and consolidates no more than five material
questions before work, asking them one per spoken turn.

The assistant may read relevant context and write wherever a clear user request requires it; the app
does not maintain a filesystem allowlist. It must do only the requested work, preserve existing
structures, and ask when the intended target or outcome is materially unclear. Destructive,
irreversible, externally visible, financial, production,
publishing, messaging, or account-changing actions require confirmation.

Optional bundled skills expose concise semantic descriptions and load their full instructions only
for matching work. Authenticated service work prefers a documented direct REST API when an existing
scoped credential supports it. A matching Jira token therefore selects Jira REST before Jira MCP;
credential and deployment types remain explicit rather than inferred from token text.

Durable named projects may use independent Codex contexts. Ordinary conversation, brainstorming,
one-off work, and ambiguous follow-ups remain in the active context. Context selection and native
idle compaction stay silent unless a real failure affects the user; expiring an inactive mapping
never deletes its Codex history or durable assistant memory.

Capabilities are used only while enabled by the user and authorized by macOS. A locked credential
vault blocks only credential-dependent work. New spoken input during a running Codex task steers
that task.
