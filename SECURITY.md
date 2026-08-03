# Security

Compass is a local-first editor: by default, nothing leaves your machine. We take that
responsibility seriously.

## Reporting a vulnerability

Email <jack@trefon.com> — do **not** open a public issue for security bugs.

What we care about most:

- Anything that would cause code or data to leave the endpoint without explicit user action
- Prompt injection or tool-loop escapes that could execute unintended commands
- Mishandling of API keys or provider credentials
- Indexing or retrieval bugs that expose content across projects

We aim to acknowledge reports within 48 hours and ship fixes in the next release. We practice
coordinated disclosure: give us a reasonable window before publishing details.

## Build integrity

Releases are currently **ad-hoc signed** (not notarized — Apple charges $99/year for that, and
Compass makes $0 until sponsors fund it; it's on the public roadmap). If you're deploying in a
sensitive environment, build from source and verify the diff:

```sh
./run.sh build
```

## The threat model

- **Local pipeline:** fully offline. No network egress by design.
- **Cloud pipeline:** opt-in only. You add your own provider key; traffic goes to your chosen
  provider, not to us. There is no Compass server, no telemetry, no account system.
- **Dependencies:** SwiftPM packages are pinned to explicit versions in `Package.resolved`.
