# ADR 0005: Homebrew-managed Codex lifecycle

## Status

Accepted

## Context

The menu-bar app is distributed outside the App Store and depends on a local Codex executable.
Requiring every user to install and update it manually makes first use and recovery fragile. Codex
CLI, ChatGPT Desktop, server behavior, and model catalogs evolve independently, so version pinning
or a compatibility matrix would become stale.

## Decision

- Discover Homebrew from installer-persisted command lookup, explicit environment configuration,
  the inherited path, or the macOS system path helper. Do not encode a Homebrew prefix.
- When Homebrew exists, ensure the latest `codex` Cask is present and select its executable. Install
  only with `brew install --cask codex`; update only with `brew upgrade --cask codex`.
- Never install Homebrew, run a broad upgrade, use `sudo`, force an update, remove another Codex
  installation, or clean unrelated packages.
- Refresh Homebrew metadata and check the Cask at most weekly while the assistant is idle. Use exact
  argument arrays, null standard input, bounded output, timeouts, and a reduced environment without
  assistant-control or credential values.
- Always keep the latest successfully installed Cask active. Do not pin or roll back versions.
- Treat signature and individual capability probes as diagnostics only. A failed signature check or
  missing optional capability produces a warning but does not block the executable.
- Show the installed Codex version as diagnostic information in the menu. Continue to discover
  models and reasoning efforts from the live account-visible app-server catalog.
- Do not automate login. Codex owns ChatGPT authentication, token refresh, workspace controls, and
  the account-visible model catalog; the user completes `codex login` when required.

## Consequences

- A user with Homebrew receives current Codex without a separate installation ritual.
- A separately installed Codex is not deleted; the app uses the Homebrew Cask it can maintain.
- Homebrew maintenance cannot update unrelated packages or inherit assistant secrets.
- Missing Codex functions degrade independently and remain visible as concrete warnings.
- New Codex, model, and effort versions require no app release merely to update a fixed matrix.

## Verification

- Missing Homebrew Codex invokes only the exact Cask installation, even if another executable exists.
- An outdated Cask invokes only the exact Cask upgrade at the weekly boundary.
- Signature or capability warnings never prevent the latest installed Cask from being selected.
- Homebrew child processes receive no assistant-control or credential environment values.
- Missing Homebrew produces one actionable warning and never falls back to another installer.
