---
name: quality-review
description: Review proposed or completed work for correctness, regressions, failure modes, security, privacy, accessibility, performance, test quality, and unnecessary complexity when review can materially improve confidence.
---

# Quality review

Review the actual artifact, relevant local instructions, diff, and public behavior. Derive only the
perspectives that can change the result; do not run a ceremonial checklist or invent reviewers.
Check the intended outcome and retained choices, including ongoing maintenance, resource, and
attention costs. Separate observed failures from hypotheses; prefer a check that distinguishes
plausible causes. Reassess the diagnosis when evidence contradicts it.

Keep review read-only unless the user explicitly asks for fixes. Lead with findings ordered by
severity. Each finding must identify the exact file, symbol, command, or observable behavior; explain
the impact; propose the smallest coherent correction; and name a verification step. Do not report
style preferences as defects unless they violate an established project rule or impair behavior.

Check the relevant subset of:

- correctness, reachable edge cases, and explicit failure behavior;
- cancellation, retry, reuse, concurrency, and cleanup ownership;
- one source of truth for parsing, validation, normalization, authorization, and persistence;
- secret exposure, trust boundaries, permissions, unsafe inputs, and externally visible actions;
- personal-data minimization, retention, deletion, and leakage through logs or errors;
- keyboard access, accessible names, focus, contrast, reduced motion, and error announcement;
- hot-path work, unnecessary refreshes, resource lifetime, and measurable regressions;
- behavior tests at the highest practical public boundary, including a regression test for fixes;
- compatibility, migration, rollback, and graceful degradation where the change crosses a boundary.

Finish with a subtraction pass. Remove or flag wrappers, branches, state, dependencies, compatibility
shims, and tests that no concrete requirement needs. Prefer a smaller obvious path over speculative
extensibility.

If there are no findings, say so plainly and list only material residual risks or unverified checks.
Verify results where they are used; successful execution alone does not establish the outcome.
For comprehensive reviews, reconcile the requested scope with inspected and missing items.
Never claim confidence or completeness that the evidence does not support.
