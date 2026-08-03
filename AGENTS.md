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

- **Entrypoint**: `CompassApp.swift:32` — `OSXIDEApp` with `@NSApplicationDelegateAdaptor AppDelegate`.
- **DI container**: `DependencyContainer.swift` — `@MainActor` class, creates all services, wires EventBus.
- **EventBus**: `Core/EventBus.swift` — central pub/sub via Combine `PassthroughSubject`. Typed events, dispatched by type name. Subscribers receive on `DispatchQueue.main`.
- **Two AI pipelines**: local (MLX 4B model for inline completion) + cloud (OpenRouter via `ConversationOrchestrator` for agentic work).
- **Vector store**: FAISS via C bridge (`Services/VectorStore/CFAISSWrapper/` + `libfaiss_full.a`). Metadata in JSON sidecar.
- **Project state dir**: `.ide/` by default, overridable via `IDE_DIR_NAME` env var. Houses logs, index, vector store, chat history, plans, checkpoints.

### Key patterns

| Pattern | Where |
|---|---|
| `actor` for isolated services | `VectorStoreService`, `ConversationLogStore`, `AppLogger` |
| `@unchecked Sendable` for Combine bags | `LogCoordinator`, `VectorStoreEmbeddingCoordinator` |
| Singletons via `shared` | `AppLogger.shared`, `ConversationLogStore.shared` |
| Event types conform to `Event` protocol | `Core/EventBus.swift:13` |
| `@MainActor` on pipeline classes | `ToolLoopHandler`, `FinalResponseHandler`, `AIToolExecutor` |
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
- Online harnesses (`AgenticHarnessTests` etc.) require `OSX_IDE_RUN_ONLINE_HARNESS=1` and **must not run in parallel** (provider rate limits).
- Test config env vars: `ALLOW_EXTERNAL_APIS`, `USE_MOCK_SERVICES`, `SWIFT_ENABLE_EXPLICIT_MODULES`.

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
- **xcodebuild package resolution** sometimes fails on first attempt for `SwiftJinja/OrderedCollections`. Running `xcodebuild -resolvePackageDependencies` fixes it.
- **Indexer uses SQLite raw** (no GRDB/CoreData). Schema in `DatabaseManager.swift`. FTS5 for full-text search.
- **Syntax highlighting**: tree-sitter via `Packages/SyntaxHighlighting`. No more token-based highlighting.
- **Some test suites take 3+ minutes** (`AIToolExecutorSchedulerTests.testWriteToolsSerializeByPath`).
