---
name: pragmatic-rest
description: Design, implement, or review ordinary HTTP/REST APIs with proportional conventions instead of imposing one company-wide response shape.
---

# Pragmatic REST

Start from the existing API contract and repository conventions. Do not silently replace GraphQL,
RPC, event streams, or an established REST style. Prefer resource-oriented paths, standard HTTP
methods and status semantics, explicit validation, and Problem Details when the project has no
better error contract.

Use these defaults only when the domain needs them:

- Represent instants crossing an API boundary as signed 64-bit Unix epoch milliseconds in UTC;
  suffix ambiguous numeric fields with `_ms`. Preserve ISO 8601 or domain-specific time types when
  an existing contract already chose them or human-readable civil time is the actual value.
- Paginate collections that can grow materially. Prefer an opaque cursor, deterministic stable
  ordering, bounded `limit`, and an explicit next cursor. Do not paginate singletons, bounded
  configuration lists, or tiny static enumerations merely for ceremony.
- Do not require a universal response envelope. Preserve native success payloads; add metadata,
  warnings, request identifiers, or page information only where consumers need them.
- Make filtering, sorting, sparse fields, expansions, and includes explicit and bounded.
- Give retryable writes an idempotency contract. Retry only transient failures and respect
  `Retry-After`; never blindly replay a non-idempotent mutation.
- Keep errors machine-readable without leaking secrets or internal stack details.

Treat these as context-sensitive design options, not scripture. State important alternatives and
choose the smallest contract that remains evolvable. For authenticated external services, also use
`.agents/skills/authenticated-rest/SKILL.md`.

When current standards matter, verify against the maintained sources rather than relying on model
memory: RFC 9110 (HTTP semantics), RFC 9457 (Problem Details), and RFC 8288 (Web Linking).
