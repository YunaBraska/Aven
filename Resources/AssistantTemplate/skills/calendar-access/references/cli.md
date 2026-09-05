# How do I search Calendar?

```sh
"$VOICE_ASSISTANT_EXECUTABLE" calendar list \
  --from 2026-09-04T00:00:00Z \
  --to 2026-09-11T00:00:00Z \
  --query optional-text \
  --limit 50
```

`--query` is optional. Dates must be ISO 8601. The command returns bounded JSON metadata and fails
when Calendar is disabled or macOS permission is absent.
