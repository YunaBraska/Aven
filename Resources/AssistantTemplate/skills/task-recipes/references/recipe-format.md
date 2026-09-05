# What is a task recipe?

Each recipe is one directory containing `recipe.json`, one executable entrypoint, and public-boundary
tests. The entrypoint supports `--help`, named options, explicit validation, predictable failures,
and `--dry-run` for external mutation.

Metadata contains name, purpose, command, parameters, creation time, last successful use, expiry,
status, and provenance. Default expiry is 90 days after successful use. Expired recipes remain
recoverable for 30 days before app maintenance removes them.

Tests use real local behavior and local fake servers only at external service boundaries. Cleanup
may never follow symbolic links or execute expired code.
