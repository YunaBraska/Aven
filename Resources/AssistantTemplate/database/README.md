# What belongs in the memory database?

`memory_records` stores small useful statements with user-defined subjects and categories. The
taxonomy is deliberately open. People, projects, places, workflows, preferences, questions, or
anything else are categories only when the conversation makes them useful.

Use `epistemic_state` to distinguish brainstorming, observation, correction, commitment, decision,
fact, preference, identity, and future categories. Temporary thought receives an expiry. Explicit
decisions do not arise from brainstorming by accident.

`style_signals` records transparent answer-shape preferences with confidence and evidence count.
`preference_rules` stores confirmed work rules at task, tool, repository, project, global, or later
discovered scopes. `assistant_identity` begins unnamed; `assistant_traits` describes the assistant's
own developing character, never the user's psychology. `memory_links` and the full-text index make
related records retrievable without prescribing a domain model. No table stores secret values or
complete transcripts.
