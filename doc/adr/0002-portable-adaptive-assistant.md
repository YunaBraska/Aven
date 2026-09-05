# ADR 0002: Portable adaptive assistant workspace

## Status

Accepted

## Context

The application is for every installed user, not one developer account. It needs durable memory,
evolving conversation style, local capabilities, and live steering without encoding a fixed set of
people, projects, paths, or personality traits.

## Decision

Bundle the canonical assistant rules, database schema, and skills inside the application. On launch,
install managed resources below the current user's Application Support directory. Preserve user-owned
memory, decisions, and recipes across app updates. Do not import or delete generic home-relative
folders; never depend on a username or fixed application path.

Use an open-ended memory graph. Records carry a free-form subject, category, epistemic state,
lifecycle, confidence, evidence count, provenance, and optional expiry. Brainstorming is temporary;
an explicit decision is never inferred merely because an idea was discussed. The assistant begins
unnamed, chooses a neutral name when first asked, and persists it. Its own traits may mature
separately from transparent user response-style signals. No psychological user profile or
manipulative questioning is allowed. Learned data remains inspectable, correctable, and deletable.

Store reusable work preferences with an explicit scope when their reach matters. Preserve existing
project structures. Research uncertainty before acting when useful. Consolidate one to five material
questions and ask them one at a time for voice clarity; proceed on stated assumptions when the user
delegates judgment.

Run Codex with local user-level file access rather than an app-maintained path allowlist. Let the
explicit task, clarity, reversibility, and authority determine whether Codex reads or writes; there
is no global read-only persona. Do only what the user requested, preserve existing structures, and
ask when the intended target or outcome is materially unclear. Ask before destructive, irreversible, externally
visible, financial, production, publishing, messaging, or account-changing actions.

Represent app capabilities in a menu and pass their effective state into each Codex request. Use
small local brokers for capabilities that need bounded data access. A menu toggle disables use by
the app; macOS System Settings remains the authority for operating-system permission revocation.
Only advertise a capability after a real broker or integration exists.

Route new spoken input during a running turn to the active Codex thread as steering. Do not expose
private chain-of-thought; speak only concise user-facing progress.

## Consequences

- The app bundle is self-contained and each macOS user receives isolated state.
- App updates can improve rules and skills without overwriting user memory.
- New domains do not require schema migrations merely to add another category.
- Adaptive behavior remains useful without becoming invisible personality surveillance.
- File writes are governed by request scope rather than a folder picker. Data integrations retain
  their explicit macOS or service capability boundaries.
