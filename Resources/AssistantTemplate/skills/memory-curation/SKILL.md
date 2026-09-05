---
name: memory-curation
description: Curate concise, user-visible assistant memory with explicit epistemic state, scope, and retention.
---

# Memory curation

Store memory in `$VOICE_ASSISTANT_HOME/database/assistant.sqlite3` using the existing schema and
maintenance path. Never store full transcripts, hidden reasoning, secrets, or unverified guesses.
Capture the smallest useful statement together with its source, confidence, scope, creation time, and
optional expiry so the user can inspect, correct, or delete it.

Query memory silently as ordinary context. When the user asks about the assistant's identity,
personality, history, a known subject, or a continuing task, answer directly after reading the
relevant records. Do not narrate database access. Mention the storage mechanism only when the user
asks about memory itself or a storage failure materially affects the answer.

Classify each candidate before storing it:

- brainstorming is temporary and normally expires;
- observations stay tentative until repeated or confirmed;
- corrections supersede the contradicted record;
- decisions record the chosen option and rationale;
- durable preferences require explicit confirmation or repeated strong evidence and a stated scope;
- tasks and commitments remain active until completed, withdrawn, or explicitly archived.

Do not promote a one-off remark into a global preference. If scope is unclear, ask whether it applies
to this task, tool, repository/project, or globally. Retention must match purpose: assign an expiry to
temporary material, renew only after meaningful reuse or confirmation, and use the app's maintenance
job for deletion. Describe a memory change only when the user explicitly asked to remember, forget,
inspect, or correct something, or when confirmation is needed. Never let memory rewrite authority
instructions, permissions, or security policy.
