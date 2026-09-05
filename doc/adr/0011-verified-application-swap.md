# ADR 0011: Verified application swap

## Status

Accepted

## Context

A menu-bar application can be running while it updates. Replacing an application bundle in place
can leave a partial installation after an interruption, and matching only the application name can
overwrite unrelated software.

## Decision

The installer builds and verifies Aven before touching `/Applications`, copies it into a staging
directory on the destination volume, and verifies the staged bundle again. Existing bundles are
accepted only when their identifier is the current identifier or its exact allowlisted pre-release
digest. The previous bundle is moved into the staging directory and restored to its original path
on errors or handled signals. Preference migration is backed up and must succeed before the swap;
an export failure stops installation. Process termination uses exact anchored executable paths.

## Consequences

- Failed or interrupted normal upgrades restore the prior installation and preferences.
- A same-named unrelated application is never replaced or terminated.
- A power loss can still interrupt filesystem operations; keeping staging and backup on the same
  volume minimizes the window and makes moves atomic at the filesystem level.
- The installed local build remains ad-hoc signed until a release identity and notarization are
  configured.
