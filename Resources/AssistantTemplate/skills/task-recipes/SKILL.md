---
name: task-recipes
description: Create, reuse, update, and retire parameterized local scripts for repeated workflows. Use after explicit automation requests or repeated successful execution, not for one-off exploration.
---

# Task recipes

Store active recipes below `$VOICE_ASSISTANT_HOME/recipes/active`. Read
[the recipe format](references/recipe-format.md) before changing or running one.

Create a recipe only when the user explicitly requests automation, the same workflow has succeeded
at least twice with clear variable inputs, or a dedicated reviewed executable is required to perform
the requested authenticated action through the credential broker. A recipe may be a dynamic,
parameterized POSIX `sh` script;
keep its executable entrypoint, named options, validation, and `--dry-run` at the public boundary. Do
not turn brainstorming or failed work into executable authority. Prefer a small script over a framework.

After successful use, extend expiry by 90 days. Failed use does not renew it. A non-credential recipe
may be reused locally with new validated parameters without repeating confirmation when the
operation is reversible and remains within its recorded scope. A credential-backed recipe may be
reused only with the exact argument list stored by the current vault; changed parameters require a
new trusted binding. Ask again when scope, destination, parameters, or side effects change; external
or destructive mutation keeps its normal confirmation boundary. Keep credentials out of recipes;
accept vault record IDs and follow the assistant-credentials skill. Never use `eval`, a mutable
request file to bypass vault scope, or shell syntax assembled from input.
