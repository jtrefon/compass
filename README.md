# Compass

> AI coding that respects your machine.

**Compass is a native AI IDE for macOS** — agentic coding with your own provider and keys, plus
on-device RAG, FIM completion, and local chat that work fully offline. ~200MB, MIT licensed,
no Electron, no lock-in.

[![CI](https://github.com/jtrefon/compass/actions/workflows/ci.yml/badge.svg)](https://github.com/jtrefon/compass/actions/workflows/ci.yml)
[![Release](https://github.com/jtrefon/compass/actions/workflows/release.yml/badge.svg)](https://github.com/jtrefon/compass/actions/workflows/release.yml)
[![Codacy Grade](https://app.codacy.com/project/badge/Grade/db02c680a7e24b90b6340b027b6ebc93)](https://app.codacy.com/gh/jtrefon/ai-ide/dashboard)
[![Quality Gate](https://sonarcloud.io/api/project_badges/measure?project=jtrefon_ai-ide&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=jtrefon_ai-ide)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=jtrefon_ai-ide&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=jtrefon_ai-ide)

---

## Why Compass exists

My MacBook Pro M4 has 16GB of RAM. Cursor and Docker were using all of it — YouTube started
stuttering, and I was swapping like it was 2009. So I built my own IDE.

Compass is the editor I use every day to build itself: a real macOS binary (SwiftUI + AppKit,
Liquid Glass, Apple Neural Engine) with two deliberately separate AI pipelines:

| | **Local pipeline** | **Cloud pipeline** |
|---|---|---|
| What it does | FIM completion (<100ms), inline Q&A, semantic search, local chat | Agentic coding: Planner → Worker → QA, 20+ tools, stall detection |
| Model | 4B on-device LLM via MLX | Your choice — OpenRouter, Kilo, DeepSeek, Alibaba, any OpenAI-compatible endpoint |
| Privacy | 100% offline, nothing leaves your machine | Opt-in only, your key, your bill |
| Network | None required. Ever. | Required for agentic work |

The local model never orchestrates. The cloud model never runs inline completion. Each does what
it's best at — that's the whole architecture in one sentence.

**Vibe code at full speed.** Bring the best model in the world, run the full agentic pipeline at
native speed, pay your provider's rate — not a per-seat tax.

**And keep working at 30,000 feet.** No network? RAG over your codebase, FIM completion, and
local chat all still work. The intelligence is on-device too.

**Nobody can sell it out from under you.** MIT, auditable, forkable, and your data stays yours.

## Quick start

Requirements: **Apple Silicon Mac, macOS 26+**, Xcode 26+ for building from source.

```sh
# Install via Homebrew (cask ships with v0.7)
brew install --cask https://raw.githubusercontent.com/jtrefon/compass/main/Casks/compass.rb

# Or grab the latest DMG/ZIP from Releases
# https://github.com/jtrefon/compass/releases
```

First launch: Compass indexes your project and pulls the on-device model. Local completion, chat,
and search work immediately — no keys, no account, no network.

For agentic coding, add your own API key (OpenRouter, Kilo, DeepSeek, any OpenAI-compatible
endpoint) in Settings → Providers. Your key, your bill, your choice.

> **The honest part:** builds are not notarized yet — Apple charges $99/year for that, and
> Compass makes $0 until sponsors fund it (roadmap item, in the open). Your Mac will warn you
> once: right-click → Open. The source is right here if you'd rather verify first.

## What's shipping

- **Real FIM completion** — ghost text in <100ms from a 4B on-device model, not a remote
  round-trip, not a fake heuristic
- **Private local chat** — ask questions, bounce ideas, get a second pair of eyes, entirely on-device
- **ANE-accelerated RAG** — SQLite FTS5 + HNSW/FAISS retrieval, embeddings on the Apple Neural Engine
- **Agentic coding, your provider** — Planner → Worker → QA orchestration, 20+ tools, harness-tested
- **Built-in terminal & browser**, tree-sitter highlighting across 20+ languages, per-project
  system prompts, command palette, project state persistence

Full detail: [FEATURES.md](FEATURES.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · website:
https://jtrefon.github.io/compass/

## Development

```sh
./run.sh app               # Build and launch
./run.sh build             # Full Xcode build
./run.sh test              # Unit tests (skips UI-heavy suites)
./run.sh test SuiteName    # Single suite filter
./run.sh harness           # Headless integration tests
./run.sh harness-online    # Live-provider suites (needs API keys, serial)
./run.sh harness-offline   # Offline suites
./run.sh benchmark-offline # Embedding model benchmarks
./run.sh e2e               # XCUITest suites
./run.sh clean             # Remove build artifacts
```

The project builds with `xcodebuild` (scheme `Compass`), not `swift build`. Derived data:
`.build/` for the app, `.build-tests/` for tests.

If package resolution fails on the first attempt (a known SwiftJinja/OrderedCollections quirk):

```sh
xcodebuild -resolvePackageDependencies -project Compass.xcodeproj
```

> **Note for AI agents:** this repo has an `AGENTS.md` — read it before touching code. It
> documents the architecture, the harness system, and the conventions the project lives by.

## The harness — the agent is tested by agents

Compass ships a headless integration harness (`CompassHarnessTests/`) that instantiates the real
app, injects a prompt, and validates the full pipeline via telemetry. No mocks, no stubs — it runs
the actual production code paths. If you touch the agent loop, `./run.sh harness` is part of the
deal. See [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Contributions are what make this project real. Start here:

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to build, test, and submit changes
- [Discussions](https://github.com/jtrefon/compass/discussions) — ideas, questions, roadmaps
- [Issues](https://github.com/jtrefon/compass/issues) — bugs and feature requests

The roadmap (v1.0 → v1.5 → v2.0) is published on the website, in the open.

## Troubleshooting

### Xcode/SourceKit "false compile errors"

Sometimes Xcode/SourceKit shows red errors (missing types, failed imports) while
`xcodebuild build` and `xcodebuild test` are green. Recovery steps, in order:

1. Quit Xcode.
2. `./run.sh clean`
3. Delete DerivedData for this project: `~/Library/Developer/Xcode/DerivedData/` (the `Compass-*` folder)
4. Re-open `Compass.xcodeproj`
5. If needed: `File > Packages > Reset Package Caches`

If it persists but `xcodebuild` is green, treat `xcodebuild` as the source of truth and file an
issue with your Xcode version, repro steps, and a screenshot.

### Terminal / shell

The embedded terminal uses the system shell (`/bin/zsh` or `/bin/bash`). If spawning a shell
fails, grant the app Full Disk Access in System Settings.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2025–2026 Jacek Trefon.
