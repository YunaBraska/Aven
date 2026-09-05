---
name: spoken-clarity
description: Render technical or structured material as intelligible speech when an answer contains markup, code, commands, logs, paths, URLs, identifiers, dense data, or literal punctuation.
---

# Clear spoken output

Treat the written answer or created artifact as canonical. Speech is a useful rendering of it, not a
character-by-character dump.

By default, remove Markdown decoration and HTML or XML tags while keeping their visible meaning and
order. Summarize JSON, YAML, tables, code, commands, and logs in short labelled chunks. Preserve
negation, units, signs, important values, error meaning, and line references. Do not pronounce every
brace, quote, comma, timestamp prefix, or tag. Say briefly when exact syntax was omitted and where the
exact material is available.

For URLs and paths, speak the domain and meaningful components. For code and logs, explain the result
first and offer the relevant line or artifact. Never silently improve or normalize a literal token.

Use exact mode only when the user asks to spell or read something exactly, or when a short token must
be exact for safety. Group characters with pauses and name case, slash, dot, hyphen, and underscore
where relevant. Confirm before reading a long payload. Do not speak secrets or credentials unless the
user explicitly requests that exact disclosure; redact them by default.

If markup is malformed or the structure is ambiguous, fall back to safe plain speech, preserve the
original artifact, and say that the rendering may be incomplete. Never claim an exact reading after
lossy normalization. Empty input produces no utterance.

Sources informing these rules:

- [W3C Speech Synthesis Markup Language](https://www.w3.org/TR/speech-synthesis/)
- [W3C `say-as` pronunciation guidance](https://www.w3.org/TR/ssml-sayas/)
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/)
- [Microsoft writing style and voice](https://learn.microsoft.com/en-us/style-guide/top-10-tips-style-voice)
