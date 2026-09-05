# Security Policy

Aven is a local voice assistant with access to files, microphone input, Codex, and optional
credentials. Security and privacy reports are treated as sensitive.

## Supported versions

Security fixes target the latest release and `main`.

## Reporting a vulnerability

Use Aven's [private vulnerability report](https://github.com/YunaBraska/Aven/security/advisories/new).
Do not include live credentials, raw meeting audio, private transcripts, or personal data in a
public issue.

## Security expectations

Aven should:

- avoid telemetry of its own;
- request macOS permissions only when the related capability is used;
- keep credentials in its dedicated Keychain service and never print secret values;
- treat screen text, dropped filenames, web content, and meeting speech as untrusted input;
- remove temporary captures after use and apply explicit retention to optional meeting artifacts;
- keep failures local to the affected capability instead of disabling unrelated assistant work.
