---
name: authenticated-rest
description: Use authenticated service APIs through scoped credentials when a documented REST interface is the best available path, including Jira, without exposing secrets or defaulting to MCP.
---

# Authenticated REST

Use the credential metadata exposed by `.agents/skills/assistant-credentials/SKILL.md` to identify the
service, account, origin, credential kind, source, expiry, and exact executable scope. Never inspect,
print, or copy the secret itself.

When a matching valid credential and documented REST API exist, prefer a narrow direct REST
connector over an MCP integration. In particular, an existing Jira token should use Jira REST by
default; use Jira MCP only when the user explicitly requests it or REST cannot provide the required
operation and the difference is explained. Do not install or enable a connector merely because it
exists.

Reuse an already reviewed dedicated connector only when its complete credential scope still matches:
executable, digest, exact arguments, environment name, destination, and purpose. Otherwise, create
the smallest connector required for the service and keep it below the assistant recipe workspace
with normal TTL maintenance. Different JQL, issue keys, fields, pages, or other arguments require a
new binding imported from a still-trusted credential source. If that source is unavailable, report
the current broker limitation instead of extracting or copying the stored secret. Never evade the
scope with a mutable request file or unscoped parameter environment. Do not bind credentials to a
shell, interpreter, generic HTTP client, or downloaded executable.

Reads must be bounded by fields, pages, and time range. Honor server pagination and rate-limit
signals. Retry only transient failures, cap attempts, and never blindly retry a non-idempotent write.
Perform writes only when the user clearly requested that external change. Report authentication,
authorization, expiry, rate-limit, and unsupported-operation failures distinctly.

For Jira, read [the Jira REST boundary](references/jira.md) before selecting authentication, API
version, pagination, or retry behavior.
