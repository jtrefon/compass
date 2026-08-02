# Contributing to Compass

First off: thank you. Compass is built in the open, and every issue, PR, and review makes it
better for everyone.

## Code of Conduct

Be excellent to each other. Compass has one rule: treat other contributors the way you'd want
to be treated. Harassment, gatekeeping, and personal attacks have no place here. If you see
something that violates this, open an issue and flag it — we take it seriously.

## What we need help with

- **Bugs** — open an issue with steps to reproduce, your Xcode version, and what you expected.
- **Feature requests** — open an issue and tell us *why* you need it, not just what.
- **Code** — check the open issues for `good first issue` labels, or pick a "Where to start"
  area from the contributors page.
- **Docs** — better docs are always welcome.

## Building

Requirements: Apple Silicon Mac, macOS 26+, Xcode 26+.

```sh
./run.sh build          # Full Xcode build
./run.sh test           # Unit tests (skips UI-heavy suites)
./run.sh test SuiteName # Single suite (e.g. LogCoordinatorTests)
./run.sh harness        # Headless integration tests
./run.sh e2e            # XCUITest suites
```

The project builds with `xcodebuild` (scheme `osx-ide`), not `swift build`. Derived data lives
in `.build/` (app) and `.build-tests/` (tests).

If package resolution fails on the first attempt (SwiftJinja/OrderedCollections quirk), run:

```sh
xcodebuild -resolvePackageDependencies -project osx-ide.xcodeproj
```

## The harness — read this before touching the agent

Compass ships a headless integration harness (`osx-ideHarnessTests/`) that instantiates the real
app container, injects a prompt, and validates the full pipeline execution via telemetry. It does
**not** mock or stub — it runs the real production code paths.

If your change touches the agent loop, tools, prompts, or finalization, run the harness:

```sh
./run.sh harness
```

If your PR is about the agent, the agent gets tested by agents. That's the deal.

## Submitting changes

1. Fork the repo and create a branch from `main`.
2. Make your change. Keep it focused — one PR, one problem.
3. Run `./run.sh test` and make sure it's green.
4. If your change touches the agent, run `./run.sh harness` too.
5. Open a PR. Describe what you changed, why, and how you verified it.

Keep commits small and messages honest — no "wip" noise. If a reviewer asks for changes, treat
the review as the gift it is.

## Licensing

Compass is MIT licensed. By submitting a PR, you agree your contribution is licensed under MIT.

## Questions?

Open a discussion or an issue. There's no such thing as a stupid question — only a question
that stays unasked.
