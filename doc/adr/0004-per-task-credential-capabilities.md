# ADR 0004: Per-task credential capabilities

## Status

Accepted

## Context

The credential vault currently binds standing consent to one credential, executable digest,
argument list, environment binding, destination, purpose, and expiry. That prevents accidental
reuse but does not prove that `vault run` belongs to the currently active assistant task. The
existing assistant-control token is per app launch, reaches the whole Codex process tree, and is not
a credential grant.

## Decision

- Keep standing credential scope separate from temporary execution authority.
- At task start, generate a random capability and keep its authoritative grant in Aven's private,
  device-bound Keychain collection. The environment value is only an opaque lookup key.
- Bind the grant to the current app session, the issuing process identity, and explicitly named
  vault, calendar, selection, or clipboard capabilities. On first authorized use, atomically bind it
  to the exact direct task-child process identity. Later uses must remain in that task subtree.
  Replace the app session at every launch so crash leftovers cannot authorize a new process tree.
- Give an unused grant a bounded activation window. Once task-bound, keep it valid for the full life
  of that process subtree instead of imposing a wall-clock expiry that can break long-running turns.
  Completion and cancellation still revoke it; process identity and ancestry make it unusable after
  task exit even if revocation is interrupted.
- Revoke every task grant on task completion or cancellation. App shutdown removes the session and
  all grants; startup removes any leftovers after an unclean exit.
- Before credential material enters a command environment, issue a separate single-use grant bound
  to the exact executable and argument array. Consume it atomically in the immediate descendant
  helper before `exec`.
- Treat an environment value only as opaque transport to the grant store, never as self-contained
  authorization.
- Remove capability and control values before starting the credential-bound executable.
- Do not allow task grants to import, rescope, delete, or otherwise mutate credential metadata.

## Consequences

- No credential token exists while the assistant is idle.
- An unrelated process cannot authorize vault use merely by invoking the app executable.
- The app can continue ordinary work when the broker or Keychain is unavailable; only the
  credential-dependent operation fails.
- A copied token is insufficient without the matching session grant and exact task-subtree identity.

## Verification

- A valid active-task grant succeeds only for its named capability and issuing process tree.
- Unused-expired, replayed, revoked, prior-session, wrong-task, wrong-capability, altered-command, and
  missing grants fail. A task-bound grant remains usable beyond fifteen minutes while that exact task
  is alive.
- The bound child environment contains neither the credential capability nor the assistant-control
  token.
- Closing the app makes every outstanding grant unusable.
