# Contributing

Keep changes focused, preserve the menu-bar-first interaction, and avoid adding persistent windows
or background work that is not needed while Aven is idle.

Before submitting a change, run:

```sh
sh scripts/check.sh
sh scripts/package.sh 0.0.1
```

`scripts/check.sh` creates the local Python validation environment when needed. `build.sh` performs
the same tests before producing an ad-hoc signed local application, and `install.sh` verifies and
launches that build from `/Applications/Aven.app`.

`Aven.xcodeproj` is checked in so normal builds need no project generator. When `project.yml`
changes, install XcodeGen and regenerate the project before building:

```sh
brew install xcodegen
xcodegen generate
```

Use AppKit and system frameworks before adding dependencies. Test behavior through public entry
points where practical. Changes to permissions, credentials, recording, persistence, routing, or
process execution need failure-path coverage and a brief decision update under `doc/adr/` when they
alter an existing boundary.

Never commit credentials, private transcripts, captured screens, generated tokens, or local
Application Support data.
