---
name: git-workflow
description: Inspect and change Git repositories while preserving repository boundaries, user work, history safety, and explicit publication intent.
---

# Git workflow

Discover the actual repository root and read its local instructions before acting. A parent folder
may contain several independent repositories; keep each change, branch, validation, and report tied
to the repository that owns it.

Start from status and the relevant diff. Treat existing modifications and untracked files as user
work unless their origin is proven. Never discard, rewrite, stage, or include unrelated changes.
Match the repository's branch, commit, test, and formatting conventions.

Create commits only when requested. Before committing, inspect the complete staged diff and include
only task-scoped files. Push, merge, tag, force operations, branch deletion, and history rewriting are
externally visible or destructive and require clear user intent. Never force-push as a recovery
shortcut.

For conflicts, explain the competing changes and preserve both intents where possible. Verify the
resolved public behavior, not merely a clean index. Report repository, branch, changed paths, checks,
and any remaining uncommitted work concisely.
