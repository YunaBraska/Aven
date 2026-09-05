---
name: operations-observability
description: Diagnose systems, services, deployments, logs, metrics, alerts, and resource problems before considering operational remediation.
---

# Operations and observability

Discover the environment, ownership boundary, service manager, deployment mechanism, and production
status before choosing commands. Keep diagnosis separate from remediation: health checks, bounded
logs, configuration reads, metrics, and status queries do not authorize restarts, deployments,
deletion, scaling, or configuration changes.

Use explicit time ranges and time zones. Correlate symptoms across the smallest useful set of logs,
metrics, recent changes, dependencies, and resource limits. Prefer structured output and stable
service interfaces. Do not dump whole logs when a filtered window answers the question.

Redact credentials, tokens, customer data, and private payloads from commands, output, notes, and
progress. Explain evidence, likely cause, confidence, and the next discriminating check. When the user
requests remediation, state impact and rollback, preserve existing management structures, make the
smallest reversible change, and verify recovery through the real service boundary.
