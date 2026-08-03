# AGENTS.md

## Commands

```sh
./run.sh build            # Full Xcode build
./run.sh test             # Unit tests (skips UI-heavy suites)
./run.sh test SuiteName   # Single suite filter (e.g. LogCoordinatorTests)
./run.sh harness          # Headless integration tests
./run.sh e2e              # XCUITest suites
./run.sh clean            # rm -rf .build .build-tests + xcodebuild clean
```

Build runs via `xcodebuild`, not `swift build`. Scheme = `Compass`. Derived data: `.build/` for app, `.build-tests/` for tests.

Package resolution: `xcodebuild -resolvePackageDependencies -project Compass.xcodeproj`.

## Architecture

- **Entrypoint**: `CompassApp.swift:32` — `CompassApp` with `@NSApplicationDelegateAdaptor AppDelegate`.
- **DI container**: `DependencyContainer.swift` — `@MainActor` class, creates all services, wires EventBus.
- **EventBus**: `Core/EventBus.swift` — central pub/sub via Combine `PassthroughSubject`. Typed events, dispatched by type name. Subscribers receive on `DispatchQueue.main`.
- **Two AI pipelines**: local (MLX 4B model for inline completion) + cloud (OpenRouter via `ConversationOrchestrator` for agentic work).
- **Vector store**: FAISS via C bridge (`Services/VectorStore/CFAISSWrapper/` + `libfaiss_full.a`). Metadata in JSON sidecar.
- **Project state dir**: `.ide/` by default, overridable via `IDE_DIR_NAME` env var. Houses logs, index, vector store, chat history, plans, checkpoints.

## Modes

Three modes, three distinct purposes. Modes are **prompt/toolset selectors only** — the agent runs the *same* tool loop, finalization, continuation, recovery, and QA review under every mode (`AIMode.isAgentic` is `true` for all; never gate agent machinery on a raw `mode == .agent` comparison). See `AIMode.swift`.

| Mode | Enum (`AIMode`) | Status | Tools | Prompt | Purpose |
|---|---|---|---|---|---|
| **Chat** | `.chat` | Shipping | All **except** mutation (`write`, `edit`, `rm`, `bash`, `write_file`, `run_command`, etc.) — read/search/browse/RAG only | `mode-chat` | Read-only co-pilot. Full search, web, and project/RAG access, but **cannot modify files or run a terminal**. For users who want the assistant to reason *with* them while they do the work themselves. |
| **Coder** | `.coder` | **Primary / main mode** | Full access (all tools) | `mode-coder` | The **agentic coding harness**. User gives instructions; Coder executes them end-to-end (read → write/edit → run → verify). `usesNewArchitecture = true`. This is what the online agentic harness tests exercise. Competitive posture: Cursor / Windsurf / Codex-style agentic coding. |
| **Agent** | `.agent` | **Planned — NOT built (stub is correct)** | Full access (same toolset as Coder) | `mode-agent` (stub: "under development and not yet operational") | Future fully-autonomous **deep-research engine** ("vibe coder"). For large/legacy efforts: architecture improvement, technical-debt reduction, legacy migration, issue hunting. Intended as a **never-ending loop** (until the user stops it or the goal is reached) that drills a subject to exhaustion — "not a single stone left unturned." Heavy, long-running (weeks/months of work). **No capacity to build this yet.** |

### Mode naming caveat (important)
The enum name `Agent` is confusing. In the user-facing architecture, "Agent" = the *planned* deep-research mode above, while everyday "agentic coding" work is **Coder**. Historically the agentic harness tests set `manager.currentMode = .agent`; they should target **`.coder`** (the primary mode) so they run with the rich `mode-coder` prompt and the non-agent iteration budget (`ToolLoopConstants.maxIterations`). Treat `.agent` as reserved/future — do not use it to exercise the main coding harness.

### Reliability focus
Current stability work targets **Coder** (the main agentic mode): zero dropouts, 100% reliability for multi-turn tasks. **Agent mode is out of scope** until capacity exists.

### Key patterns

| Pattern | Where |
|---|---|
| `actor` for isolated services | `VectorStoreService`, `ConversationLogStore`, `AppLogger` |
| `@unchecked Sendable` for Combine bags | `LogCoordinator`, `VectorStoreEmbeddingCoordinator` |
| Singletons via `shared` | `AppLogger.shared`, `ConversationLogStore.shared` |
| Event types conform to `Event` protocol | `Core/EventBus.swift:13` |
| `@MainActor` on pipeline classes | `ConversationSendCoordinator`, `Orchestration` nodes, `AIToolExecutor` |
| Codegen: none. SPM packages under `Packages/` | `SyntaxHighlighting`, `Terminal` |

### .ide directory structure

```
.ide/
├── chat/                 # Conversation history
├── checkpoints/          # Agent checkpoints
├── index/                # Codebase SQLite (FTS5 + symbols)
├── logs/
│   └── conversations/    # NDJSON per conversation (conversation.ndjson + executions.ndjson)
├── orchestration/        # Run snapshots
├── plans/                # Task plans
├── staging/              # Staged diffs
├── vector_store/         # FAISS index + metadata.json
├── index_exclude         # Exclude patterns file
└── session.json          # UI state
```

### Vector store data flow

```
ContextLogEvent / ToolResultEvent → EventBus
  ├── LogCoordinator → writes NDJSON to .ide/logs/
  └── VectorStoreEmbeddingCoordinator
       ├── buffers user_message, pairs with assistant_message
       ├── generates embedding via HashingMemoryEmbeddingGenerator
       └── stores (vector + SourceReference) in FAISS
```

## Testing

- **Swift Testing** (`import Testing`) used in newer tests (`LogCoordinatorTests`).
- **XCTest** (`import XCTest`) used in older tests (`AIToolExecutorSchedulerTests`).
- Unit tests: `./run.sh test` — skips 6 UI-heavy suites that need AppKit rendering.
- Harness tests: `./run.sh harness` — headless integration, memory-guarded (6GB default).
- Online harnesses (`WebSearchHarnessTests` etc.) require `OSX_IDE_RUN_ONLINE_HARNESS=1` and **must not run in parallel** (provider rate limits).
- Test config env vars: `ALLOW_EXTERNAL_APIS`, `USE_MOCK_SERVICES`, `SWIFT_ENABLE_EXPLICIT_MODULES`.

## Harness System (`CompassHarnessTests/`)

### What it is

The harness is a **headless XCTest suite** that instantiates the real app's `DependencyContainer`, injects a prompt, monitors the full pipeline execution, and validates outcomes via telemetry. It does **not** mock or stub — it runs the actual production code paths, making it the closest thing to an integration test without launching the UI.

### Key principle

> The harness implements no application logic. It orchestrates the existing app implementation via prompts, collects telemetry to understand behavior, and validates results. No code duplication, no disconnect from the real app.

### How it works

1. Each suite has a local `makeRuntime()` helper that creates a real `DependencyContainer` with `AppLaunchContext.detect()`, wires a temp project root, and sets the conversation manager's `currentMode` (`.coder` for tool-using agentic work, `.chat` for read-only) — mode is a prompt/toolset selector; setting it is orchestration, not implementation
2. Calls `sendMessage()` like the UI would, then polls `manager.isSending` until completion or timeout
3. After completion, inspects `manager.messages`, files on disk, and `OrchestrationRunSnapshot` files in `.ide/orchestration/`
4. Validates assertions (files exist, no raw tool markup leaked, context immutability, answer not wiped)

### Running

```sh
# All harness suites (memory-guarded, 6GB default; online suites gated by env var)
./run.sh harness

# Single suite
./run.sh harness PureAgenticHarnessTests

# Online suites (requires API keys — serial execution enforced)
OSX_IDE_RUN_ONLINE_HARNESS=1 ./run.sh harness WebSearchHarnessTests

# Convenience commands
./run.sh harness-online              # Runs the online suites (WebSearch, WordPressReview, ReproCrash)
./run.sh harness-online WebSearchHarnessTests
./run.sh harness-offline              # Runs the offline suites (PureAgenticHarnessTests, StripMarkupTest, ...)
./run.sh harness-offline PureAgenticHarnessTests
```

### Harness variants

| Command | Env var | Suites | Purpose |
|---|---|---|---|
| `harness` | `OSX_IDE_RUN_ONLINE_HARNESS=1` to include online | All harness suites: `PureAgenticHarnessTests`, `StripMarkupTest`, `RAGPreventionHarnessTests`, `WebSearchHarnessTests`, `WordPressReviewReproductionTests`, `ReproCrashTest`, `EmbeddingBenchmarkHarnessTests` | Headless integration tests |
| `harness-online` | `OSX_IDE_RUN_ONLINE_HARNESS=1` (set automatically) | `WebSearchHarnessTests`, `WordPressReviewReproductionTests`, `ReproCrashTest` | Live-provider end-to-end runs |
| `harness-offline` | — | Offline suites (`PureAgenticHarnessTests`, `StripMarkupTest`, `RAGPreventionHarnessTests`, `EmbeddingBenchmarkHarnessTests`) | No provider traffic |
| `benchmark-offline` | — | `EmbeddingBenchmarkHarnessTests` | Embedding model benchmarks |

### Online execution gate

`OnlineHarnessExecutionGate.shared` is an actor that serializes online test access:
- `acquire()` blocks until the gate is free (one test at a time)
- `release()` unblocks the next waiter or resets to free
- Prevents parallel provider traffic (429 floods / account bans)

Online suites are skipped unless `OSX_IDE_RUN_ONLINE_HARNESS=1` is set (checked by `run.sh` and the gate).

### Memory guard

`run.sh` wraps all harness runs in `run_with_memory_guard()`:
- Default limit: 6GB (`HARNESS_MAX_RSS_GB` env var)
- Polls RSS every 3s during execution
- Kills the process tree if exceeded
- Prints `[harness-memory]` diagnostics on each poll

### Telemetry collected

The harness prints structured output prefixed with `[HARNESS]`:

| Method | What it captures |
|---|---|
| `logTelemetry` | Message count, tool execution count by tool name, streaming draft state |
| `sendAndWait` | Sends a prompt and polls `manager.isSending` to completion with a deadline |
| `assertNoRawToolMarkup` | Verifies `<tool_call>`, `<tool_code>`, `call:name{...}` etc. didn't leak into the final answer |
| `readSnapshots` (app-side) | `OrchestrationRunSnapshot` JSONL under `.ide/orchestration/runs/` |

### Writing a new harness test

```swift
@MainActor
final class MyHarnessTests: XCTestCase {
    // Copy the makeRuntime() + sendAndWait() helpers from PureAgenticHarnessTests
    func testHarnessMyScenario() async throws {
        let runtime = try await makeRuntime()          // temp root + real container + .coder mode
        let manager = runtime.manager

        try await sendAndWait("Your prompt here", manager: manager, timeout: 300)

        // Validate observable outcomes
        let files = listAllFiles(under: runtime.projectRoot)
        logHarnessCheck(files.contains("expected-file"), label: "file was created")
        assertNoRawToolMarkup(manager)
    }
}
```

### Environment variables

| Variable | Effect |
|---|---|
| `OSX_IDE_RUN_ONLINE_HARNESS=1` | Enables online harness suites (requires API keys) |
| `HARNESS_MAX_RSS_GB` | Memory guard limit (default: 6) |
| `HARNESS_MODEL_ID` | Override the AI model used |
| `HARNESS_USE_OPENROUTER` | Force OpenRouter provider |
| `HARNESS_TEST_PROFILE_DIR` | Directory for test profile artifacts |
| `OSXIDE_DISABLE_HEAVY_INIT` | Skip heavy initialization in test runtime |
| `OSXIDE_ENABLE_PRODUCTION_PARITY_HARNESS` | Enable production parity mode |
| `OSXIDE_LOCAL_MODEL_MAX_RSS_MB` | Local model memory budget |
| `OSX_IDE_PROMPTS_ROOT` | Override prompts directory |
| `OSXIDE_DEGRADE_ON_TRANSPORT_FAILURE` | Graceful degradation on transport failure |
| `OSXIDE_FALLBACK_MODEL_ID` | Fallback model ID |
| `OSXIDE_CIRCUIT_FAILURE_THRESHOLD` | Circuit breaker threshold |
| `OSXIDE_CIRCUIT_COOLDOWN_SEC` | Circuit breaker cooldown seconds |

### Test tools used by harness

- `OnlineHarnessExecutionGate.shared` — serial gate for online tests
- `TestConfiguration` / `TestConfigurationProvider` — app-target configuration helpers (also used by unit tests)
- `ToolExecutionEnvelope` (Models) — decode tool execution status from message content

## Pill Tab Implementation (DO NOT ALTER)

`EditorTabBar.swift` and the tab section of `AIChatPanel.swift` use a hard-won architecture that took many iterations to get right on macOS 26. Changes to this pattern WILL break tab functionality.

### The working pattern (mandatory):

```
Button(onActivate)                          ← single button, fills entire pill
  HStack
    Spacer(minLength: 4)                    ← pushes content to center
    FileTabIcon / Image                     ← file type icon (left of label)
    Text                                    ← tab name
    if isDirty { Circle() }                 ← dirty indicator
    Spacer(minLength: 4)                    ← pushes content to center
  .padding(.horizontal, 10)
  .padding(.vertical, 6)
  .background { Capsule()... }             ← entire pill is clickable via Button
.buttonStyle(.plain)
.frame(minWidth: 80)
.frame(maxWidth: .infinity)                ← fills bar width equally
.overlay(alignment: .leading) {            ← close button on top of pill
  Button(onClose) { Image("xmark") }
}
.overlay(MiddleClickView...)               ← middle-click close (AppKit hitTest override)
```

### Rules:
1. **Single `Button` wrapping the entire pill** — the Button's hit area is the entire pill. Do NOT use sibling Buttons, ZStack with Buttons, or onTapGesture.
2. **Close button as `.overlay(alignment: .leading)`** — sits on top, intercepts taps in its zone. Never nest it inside the main Button.
3. **`Spacer` on both sides** — centers the content. A single trailing Spacer left-aligns.
4. **No `ScrollView`** — prevents gesture interference. Use plain `HStack` + `.frame(maxWidth: .infinity)` for equal width distribution.
5. **No `GeometryReader`** — can interfere with child gesture recognizers.
6. **Inactive tabs** use `Color(nsColor: .windowBackgroundColor).opacity(0.35)` with hover at `0.5`. Active tabs use `.glassEffect(.regular, in: Capsule())`.
7. **Hover** handled via `.onHover` on the tab + conditional in background fill/stroke.

## Gotchas

- **LSP false positives**: sourcekit-lsp frequently reports "Cannot find type 'X' in scope" for cross-module types. The actual build (`./run.sh build`) is the source of truth.
- **FAISS**: linked as a static library (`libfaiss_full.a`). The C bridge (`CFAISSWrapper.c`) wraps `faiss_c.h`. No Swift Package Manager dependency.
- **Workflow permissions + Dependabot**: GitHub requires MANUAL APPROVAL for any workflow run triggered by a Dependabot PR that requests write permissions (hard security gate, cannot be disabled). Rule: write-permission workflows must be push-triggered or manual (`workflow_dispatch`) — never `pull_request`-triggered for dependabot-covered events. See `.github/workflows/auto-merge.yml` for the working pattern.

### Design Standards (UI consistency)

**All UI spacing, corner radii, colors, control heights, and shared sizes MUST come from `AppConstants` (`Compass/Services/AppConstants*.swift`). Never hardcode these as magic numbers in component code** — if a needed value is missing, add it to the appropriate `AppConstants*` file. Full rules, token tables, and DO/DON'T examples are in [`DESIGN_STANDARDS.md`](./DESIGN_STANDARDS.md).

Hard rules (see `DESIGN_STANDARDS.md` for detail):
1. Adjacent controls of the same role (e.g. mode selector + model selector) **must share one component/idiom** — do not mix a native `Picker(.menu)` with a custom `Button`+`popover` bubble. This previously produced mismatched heights/fonts.
2. Headers use `AppConstants.Layout.headerHeight`; dividers use `AppConstants.Color.separatorDefault`.
3. Corner radii use `AppConstants.Layout.corner*` tokens (the scale tops out at `cornerXL = 16`; `cornerRadius: 18` is a violation).
4. Glass surfaces use `nativeGlassBackground(_:)` / `NativeGlassSurface`, not hand-rolled materials.
5. SwiftLint's `hardcoded_corner_radius` guardrail warns on literal `cornerRadius:` values — treat as must-fix for UI code.
- **xcodebuild package resolution** sometimes fails on first attempt for `SwiftJinja/OrderedCollections`. Running `xcodebuild -resolvePackageDependencies` fixes it.
- **Indexer uses SQLite raw** (no GRDB/CoreData). Schema in `DatabaseManager.swift`. Symbol search is `LIKE`-based; full-text search runs via a bounded `grep` subprocess (`CodebaseIndex+TextSearch.swift`) — FTS5 was dropped.
- **Syntax highlighting**: tree-sitter via `Packages/SyntaxHighlighting`. No more token-based highlighting.
- **Some test suites take 3+ minutes** (`AIToolExecutorSchedulerTests.testWriteToolsSerializeByPath`).
