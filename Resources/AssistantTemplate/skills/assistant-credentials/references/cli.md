# How do I use the credential broker?

Metadata-only commands:

```sh
"$VOICE_ASSISTANT_EXECUTABLE" vault status
"$VOICE_ASSISTANT_EXECUTABLE" vault list
"$VOICE_ASSISTANT_EXECUTABLE" vault refresh
"$VOICE_ASSISTANT_EXECUTABLE" vault env-keys --file /absolute/path/.env.local
```

Import one exact value without printing it:

```sh
"$VOICE_ASSISTANT_EXECUTABLE" vault import-env \
  --service service.example \
  --account account-name \
  --kind token \
  --purpose 'API access' \
  --origin https://service.example \
  --executable /absolute/path/to/reviewed-jira-reader \
  --environment SERVICE_TOKEN \
  --operation 'read Jira issues' \
  --argument issues \
  --file /absolute/path/.env.local \
  --key SERVICE_TOKEN
```

Kinds are `password`, `token`, `totp_seed`, and `browser_session`. Import browser sessions with
`import-file`. Add `--ttl-seconds` when needed. Repeat `--argument` in exact command order. The
broker stores the canonical executable path, its SHA-256 digest, the environment name, exact
arguments, operation, and destination. Changing any of them requires a new reviewed binding.

Use a returned record ID without exposing its value:

```sh
"$VOICE_ASSISTANT_EXECUTABLE" vault run \
  --bind RECORD_ID=SERVICE_TOKEN \
  --timeout-seconds 120 \
  -- /absolute/path/to/reviewed-tool --option value
```

Remove an obsolete record with `vault remove RECORD_ID`. Output scrubbing reduces accidental
disclosure. Generic shells, interpreters, network clients, and modified executables are rejected;
use a narrow dedicated script or tool whose exact command matches the stored scope.
