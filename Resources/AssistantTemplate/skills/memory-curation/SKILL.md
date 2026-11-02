---
name: memory-curation
description: Retrieve relevant memory and learn conditional work or response preferences from corrections, choices, and recurring behavior; curate scope, evidence, and retention.
---

# Memory curation

Use `$VOICE_ASSISTANT_HOME/database/assistant.sqlite3` and `database/schema.sql`. Enable
`PRAGMA foreign_keys = ON` on every connection. Keep subjects and categories open-ended; use only
supported relationships. Store concise statements with source, confidence, dates, and appropriate
expiry, never transcripts, hidden reasoning, secrets, unnecessary personal data, or guesses as facts.

Retrieve silently before a material decision or recommendation, when continuing work, or for an
identity/history question. Reuse relevant context already loaded; otherwise select a bounded set of
active, unexpired rules and related records. Search by the decision or behavior as well as the topic,
using the full-text index and supported links. Judge applicability from meaning and conditions,
not keyword overlap alone. Never dump the database into a prompt. Refresh after a correction or
changed constraint; memory does not override the current request or grant permission.

Classify before storing:

- brainstorming is temporary and normally expires;
- observations stay tentative until repeated or confirmed;
- corrections supersede the contradicted record;
- decisions record the chosen option and rationale;
- durable preferences require explicit confirmation or repeated strong evidence and a stated scope;
- tasks and commitments remain active until completed, withdrawn, or explicitly archived.

Learn the behavior behind a correction, not a rule tied to incidental names or technologies.
In `preference_rules.rule`, state when it applies, the desired behavior, and the observable success
criterion; include an exception only when supported. Keep source and scope separate. Global scope
permits reuse across topics, not unconditional application. Store answer-shape preferences with
their conditions and independent evidence count in `style_signals`; tentative style observations
remain in `memory_records`. Assistant character belongs in `assistant_traits`.

Compare related rules before writing. Merge equivalent evidence without counting copied text or
repeated boilerplate as independent confirmation. Distinguish different conditions from genuine
contradictions; retain conditional preferences together and supersede the affected rule only when
replaced. Inferred work rules start as `candidate` with `explicit = 0`. Activate only after scope is
confirmed and either explicit confirmation or repeated strong independent evidence supports the
rule. Clarify unclear reach before broadening it. Do not encode every correction as a new skill or
instruction file.

Expire temporary candidates; durable rules remain until superseded or retracted. Renew retention
only after meaningful reuse or confirmation. Use the app's scheduled `database/maintain.sql` path
for deletion. Describe memory changes only when asked to remember, forget, inspect, or correct, or
when confirmation or a storage failure affects the task. Memory never rewrites authority,
permissions, or security policy.
