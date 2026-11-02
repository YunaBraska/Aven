# How does Aven decide what to do?

Aven assembles behavior from four visible layers. None of them contains hard-coded model names.

1. `Sources/CodexClient.swift` adds only changing per-turn facts: the current system speech language
   and capability boundary. It does not repeat the durable assistant prompt inside every user turn.
2. `Resources/AssistantTemplate/AGENTS.md` is the durable assistant contract. It defines identity,
   clarification, memory, project context, delegation, permissions, and response behavior.
3. `Resources/AssistantTemplate/decisions/assistant-policy.md` records the durable product choices
   that must survive managed skill updates.
4. `Resources/AssistantTemplate/skills/*/SKILL.md` contains optional task-specific instructions.
   Startup discovers every valid bundle dynamically and synchronizes it to `.agents/skills`, where
   Codex loads a skill only when its semantic description matches the current task.

The contract routes adaptive behavior to `memory-curation`: user work rules live in SQLite
`preference_rules`, answer-shape preferences in `style_signals`, and the assistant's own character
in `assistant_traits`. Rules describe conditions, behavior, and an observable outcome, so their
meaning can transfer across topics. Only relevant active context is retrieved; corrections update
the applicable rule rather than growing the permanent prompt. Retrieval is instruction-driven by
Codex, not a Swift memory-injection or enforcement layer.

Before a normal turn, `Sources/ModelRouter.swift` asks a short isolated Codex planning pass to select
from the live model and effort catalog and to choose an existing project context when appropriate.
The planner itself is selected from live structured capabilities, preferring an available text-only
model; it is not selected by matching words in the user's request.
The catalog is cached for six hours. Each new turn is still classified because a later request may
have different risk or complexity; a planning pass is bounded to three seconds and falls back to the
current Codex default. After any slow routing pass, three turns use the live default without paying
the failed routing latency, then semantic routing is tried again. Additional input during an active
task uses Codex steering directly and does not run this planning pass again.

These layers are silent implementation context. They must not appear as preambles such as “I am an
assistant”, “I selected a skill”, “I checked memory”, or “I am finding something that works without
a screen”. A spoken answer begins with useful content. Internal mechanisms are explained only when
the user asks about them, and a capability limit is mentioned only when it changes the result.

Codex starts a task once and later uses `exec resume` with its stored thread identifier. The durable
assistant contract remains available as workspace `AGENTS.md`; only the new user request and compact
dynamic turn facts are appended to a resumed task. This keeps continuity without filling the
conversation with duplicate copies of the default instructions.

The installed managed copies live below Aven's Application Support workspace. Updates may refresh
managed rules and skills, but they do not rewrite user memory, identity, project mappings, recipes,
or credentials.
