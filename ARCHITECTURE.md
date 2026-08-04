> **STALE — historical reference only (July 2026).** This document describes the
> pre-refactor architecture (ToolLoopHandler / FinalResponseHandler / QA review,
> `Conversation/` domain layer). Those components were replaced by the
> **Orchestration graph** (see `Compass/Services/Orchestration/`,
> `ConversationSendCoordinator`, `AIToolExecutor` + `ToolExecutionSupport`) in
> the July 2026 refactor. **AGENTS.md is the source of truth** for the current
> architecture; treat anything in this file that contradicts it as obsolete.

# Architecture Documentation

## Overview

Compass is a native macOS IDE with dual AI pipelines — a local pipeline powered by a 4B MLX model for instant, private daily coding, and a cloud pipeline powered by OpenRouter for agentic, multi-file work at scale. The two pipelines share an editor and infrastructure but are architecturally independent.

## Core Architecture

### Dual-Pipeline Design

```
┌──────────────────────────────────────────────────────────────────┐
│                        UI LAYER                                  │
│  SwiftUI Views · AppKit Components · NSTextView · Terminal      │
│  File Tree · Command Palette · Panels · Settings                 │
├──────────────────────────────────────────────────────────────────┤
│                        CORE LAYER                                │
│  EventBus · CommandRegistry · DependencyContainer · Models       │
├──────────────────────────────────────────────────────────────────┤
│                     SHARED SERVICES                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ CodebaseIndex│  │ Tool Impls   │  │ FileSystem · Terminal  │ │
│  │ SQLite, FTS5, │  │ (AITool      │  │ Session · Settings    │ │
│  │ symbols,      │  │  protocol)   │  │ EventBus              │ │
│  │ embeddings    │  │              │  │                        │ │
│  └──────────────┘  └──────────────┘  └────────────────────────┘ │
├──────────────────────┬───────────────────────────────────────────┤
│   LOCAL AI PIPELINE  │           CLOUD AI PIPELINE               │
│                      │                                           │
│ ┌──────────────────┐ │ ┌──────────────────────────────────────┐ │
│ │ LocalInteraction │ │ │ ConversationOrchestrator             │ │
│ │ Service          │ │ │ ┌──────────┐                         │ │
│ │ ─ Direct LLM     │ │ │ │ Planner  │                         │ │
│ │   call to 4B MLX │ │ │ └────┬─────┘                         │ │
│ │ ─ No orchestrate │ │ │      v                               │ │
│ │ ─ No tool loop   │ │ │ ┌──────────┐  ┌──────────────┐     │ │
│ │ ─ No RAG injection│ │ │ │ Worker   │→│ Tool Executor│     │ │
│ │ ─ Simpler context │ │ │ │(ToolLoop)│  │ (AITool impls)│     │ │
│ └──────────────────┘ │ │ └────┬─────┘  └──────────────┘     │ │
│                      │ │      v                               │ │
│ ┌──────────────────┐ │ │ ┌──────────┐                         │ │
│ │ InlineCompletion │ │ │ │ QAReview │                         │ │
│ │ Engine            │ │ │ └────┬─────┘                         │ │
│ │ ─ 4B MLX <100ms  │ │ │      v                               │ │
│ │ ─ Ghost text      │ │ │ ┌──────────┐                         │ │
│ │ ─ Cache + rank    │ │ │ │ Final    │                         │ │
│ └──────────────────┘ │ │ └──────────┘                         │ │
│                      │ └──────────────────────────────────────┘ │
│ ┌──────────────────┐ │ ┌──────────────────────────────────────┐ │
│ │ InlinePopover    │ │ │ RAGEngine                             │ │
│ │ ─ Cursor-anchored│ │ │ ─ Retrieval + ranking                │ │
│ │ ─ File-scoped QA │ │ │ ─ Context injection (cloud only)     │ │
│ │ ─ Quick explain   │ │ │ ─ Evidence fusion                   │ │
│ └──────────────────┘ │ └──────────────────────────────────────┘ │
└──────────────────────┴───────────────────────────────────────────┘
```

### Key Architectural Decision: Two Separate AI Pipelines

Local and cloud pipelines share ZERO AI execution code. The only shared components are:

| Shared Component | Used By | How |
|---|---|---|
| CodebaseIndex | Both | Read-only queries for context and search |
| Tool implementations (AITool protocol) | Cloud only | Executed by ToolLoopHandler |
| FileSystemService | Both | File I/O for context and tool results |
| TerminalService | Both | Terminal operations |
| EventBus | Both | Events for telemetry and UI updates |
| CommandRegistry | Both | Commands triggered by AI or user |
| DependencyContainer | Both | DI for shared services |

## Component Architecture

### 1. CodebaseIndex (`Services/Index/`)

The shared knowledge foundation. An SQLite database with FTS5 full-text search, symbol extraction, and embedding-based semantic search.

**Key capabilities:**
- File indexing with content hashing (skip unchanged files)
- FTS5 full-text search with ranking
- Symbol extraction (Swift, TypeScript, JavaScript, Python, regex fallback)
- Semantic search via embedding vectors (O(n) currently, target: ANN)
- File watching with intelligent debouncing

**Consumers:**
- Local pipeline: semantic search, symbol resolution for inline features
- Cloud pipeline: RAG retrieval, tool-backed search (index_find_files, index_search_text, etc.)
- UI: workspace search, symbol search

**Database schema:**
- `resources` — one row per indexed file (path, language, hash, summary)
- `resources_fts` — FTS5 virtual table for full-text search
- `symbols` — extracted symbols with location and kind
- `code_chunks` — overlapping chunks with embedding vectors

### 2. Local AI Pipeline (`Services/LocalPipeline/`)

A minimal, fast path for the 4B MLX model.

**Components:**

```
LocalInteractionService
  ─ receives: user input + optional explicit context (current file, selection)
  ─ optionally queries CodebaseIndex for relevant context
  ─ calls: LocalModelProcessAIService (4B MLX)
  ─ returns: text response

InlineCompletionEngine
  ─ triggered by: text change events (debounced)
  ─ builds: completion context (prefix, suffix, scope)
  ─ optionally: retrieves context from CodebaseIndex
  ─ calls: 4B MLX model for inline completion
  ─ renders: ghost text in NSTextView
  ─ accepts: Tab, dismisses: Esc

InlinePopoverService
  ─ triggered by: Cmd+I / selection context menu
  ─ reads: current selection, file contents
  ─ shows: floating popover anchored to cursor
  ─ supports: explain, refactor, quick transform, find similar
  ─ calls: 4B MLX model
```

**What the local pipeline does NOT have:**
- No orchestration graph (no Planner, Worker, QA nodes)
- No tool loop (no iterative tool execution)
- No RAG context injection (context is explicitly requested, not prepended)
- No planning or strategy synthesis
- No conversation folding or memory management

### 3. Cloud AI Pipeline (`Services/CloudPipeline/`)

A full-featured, graph-based orchestration pipeline for agentic coding with cloud models via OpenRouter.

**Components:**

```
ConversationOrchestrator
  ─ entry point for cloud AI interactions
  ─ builds the execution graph:
      StrategicPlanning → TacticalPlanning → Dispatcher
        → ToolLoop (iterative) → BranchReview
          → (optional) QAToolOutputReview → QAQualityReview
        → FinalResponse

RAGEngine
  ─ only used in cloud pipeline
  ─ retrieves codebase context via CodebaseIndex
  ─ classifies intent (bugfix, feature, refactor, etc.)
  ─ fuses evidence with ranking (semantic + structural + recency)
  ─ injects as "RAG CONTEXT:" block in cloud requests

ToolLoopHandler
  ─ iterative execution loop with stall detection
  ─ deduplication, mutation tracking, recovery strategies
  ─ max iterations: 50 (configurable)
  ─ only runs for cloud model requests

Tool implementations
  ─ conform to AITool protocol
  ─ shared implementations, NOT shared execution loop
  ─ cloud pipeline executes them via ToolLoopHandler
```

**What the cloud pipeline does NOT do:**
- No inline completion (that's local-only)
- No inline popover Q&A (that's local-only)
- No direct file-level quick transforms (those are local-only)

### 4. AI Router (`Services/AIRouter.swift`)

The component that decides which pipeline handles a given request.

**Routing logic:**

| User Action | Route | Why |
|---|---|---|
| Typing (completion) | Local | Latency-critical, context-limited |
| Cmd+I on selection (explain) | Local | Single file, instant desired |
| Cmd+Shift+I (inline chat) | Local | Cursor-anchored, file-scoped |
| Chat panel message (local mode) | Local | User chose local |
| Chat panel message (cloud mode) | Cloud | User chose cloud |
| Agentic task ("refactor X across project") | Cloud | Needs tools, multi-file |
| Semantic search (Cmd+Shift+F) | CodebaseIndex directly | No AI needed |
| Diagnostics explanation | Local | Single file, instant |

**Explicit user control:**
- Chat panel has a local/cloud toggle per conversation
- Agentic mode toggle enables cloud pipeline for chat
- Completion and inline features are always local
- Future: smart auto-routing based on query complexity

### 5. ConversationManager (`Services/ConversationManager.swift`)

**Planned refactoring target.** Currently a god object managing both pipelines. Will be split into:

```
ConversationManager (simplified router)
  ├── LocalInteractionService (new, simple)
  ├── CloudConversationService (extracted from current manager)
  └── SessionManager (tabs, history, state)
```

### 6. Tool System (`Services/Tools/`)

Individual tool implementations conforming to `AITool` protocol. These are the actual operations (read file, write file, search, execute command, etc.).

**Key design:**
- Tools are shared between pipelines as implementation code
- Only the cloud pipeline executes tools iteratively via ToolLoopHandler
- The local pipeline never invokes tools (too unreliable for 4B model)
- Tools have no knowledge of which pipeline invoked them

## Data Flow

### Local Pipeline: Inline Q&A

```
User selects code → Cmd+I
  → InlinePopoverService.show(for: selection)
    → reads current file from FileEditorService
    → builds prompt: "Explain this code: ..."
    → calls LocalModelProcessAIService.generate(prompt)
    → 4B MLX model responds
  → shows response in cursor-anchored popover
  → user dismisses with Esc
  Total: ~100-300ms
```

### Local Pipeline: Code Completion

```
User types character
  → NSTextView.textDidChange
    → EditorSignalBridge.scheduleAutomaticRequest()
      → InlineCompletionEngine.requestCompletion()
        → CompletionContextAssembler.buildContext() (prefix, suffix, scope)
        → CompletionInferenceService.infer() → 4B MLX model
        → SuggestionRanker.evaluate()
        → publish suggestion
      → CodeEditorTextView.showGhostText(suggestion)
  → User presses Tab → accept
  Total: ~50-150ms
```

### Cloud Pipeline: Agentic Request

```
User types: "Add error handling to all API routes"
  → ConversationManager routes to CloudConversationService
    → ConversationOrchestrator.run()
      → DispatcherNode (sends initial LLM response)
        → model responds with tool calls
      → ToolLoopNode:
        [loop] → execute tool calls → send follow-up → repeat
        → stall detection, mutation tracking, recovery
      → BranchReviewNode (check if branch complete)
      → FinalResponseNode (format summary)
    → response shown in chat panel
  Total: ~5-60s (depending on complexity)
```

## Semantic Search (HNSW Index)

The codebase index uses an in-memory HNSW (Hierarchical Navigable Small World) graph for approximate nearest-neighbor search over embedding vectors. This replaces the O(n) brute-force SQLite scan that loaded all vectors into memory on every query.

**Implementation:** `Services/Index/Search/HNSWIndex.swift`

**Key parameters:** M=16, efConstruction=200, efSearch=50, mL=1/ln(M). Estimates: 10-50x speedup over brute-force at ~95-99% recall.

**Per-modelId indices:** Separate HNSW graphs for each embedding model (e.g., hashing, CoreML, BERT). Lazily rebuilt from SQLite on first search after model change or data mutation. Incremental insert/remove on save/delete. Post-filter by memory tier (3x over-fetch, then filter).

**Managers using HNSW:**
- `DatabaseMemoryManager` — memory embeddings
- `DatabaseCodeChunkManager` — code chunk embeddings (composite key: `resourceId:chunkIndex`)

## Pipeline Isolation Rules

1. **No shared state** between pipelines beyond what's in shared services. Local and cloud conversations have separate histories, separate contexts, separate caches.

2. **No shared execution code.** Local code path is simple: prompt → model → response. Cloud code path is complex: plan → execute → loop → review → final. They share zero lines of AI execution logic.

3. **RAG is cloud-only.** The local model gets explicit context (current file, selection) — not a RAG-injected context block. If the local model needs codebase context, it's queried explicitly from the index.

4. **Tools are cloud-only.** The local model never invokes tools. It would be unreliable and slow. Tools are for cloud models with sufficient reasoning capability.

5. **Inline completion is local-only.** Never route a completion request to the cloud. The latency would defeat the purpose.

## Service Layer Responsibilities

### Shared (non-AI) Services

| Service | Responsibility |
|---|---|
| `EventBus` | Typed event publish/subscribe |
| `CommandRegistry` | Command registration and execution |
| `DependencyContainer` | DI container (migrate singletons here) |
| `FileSystemService` | File I/O operations |
| `WorkspaceService` | Project management, path resolution |
| `FileEditorService` | Open file state management |
| `TerminalService` | Terminal emulation |
| `SessionService` | Layout persistence |
| `ErrorManager` | Error logging and reporting |
| `PowerManagementService` | Prevent sleep during AI activity |
| `SettingsStore` | User preferences (UserDefaults + Keychain) |

### Local Pipeline Services

| Service | Responsibility |
|---|---|
| `LocalInteractionService` | Direct 4B model interaction for Q&A |
| `InlineCompletionEngine` | Ghost text code completion |
| `InlinePopoverService` | Cursor-anchored assistant |
| `LocalModelProcessAIService` | MLX model loading and inference |

### Cloud Pipeline Services

| Service | Responsibility |
|---|---|
| `ConversationOrchestrator` | Graph-based orchestration |
| `RAGEngine` | Codebase context retrieval and injection |
| `ToolLoopHandler` | Iterative tool execution loop |
| `QAReviewHandler` | Quality assurance review |
| `OpenRouterAIService` | Cloud model API client |
| `PlanningService` | Strategic/tactical plan synthesis |

## Directory Structure (Target)

```
Compass/
├── Core/                     # Shared infrastructure
│   ├── EventBus/
│   ├── CommandRegistry/
│   ├── DependencyContainer/
│   ├── StandardCommands.swift
│   └── Models/
├── Components/               # UI components
│   ├── Editor/
│   ├── FileTree/
│   ├── Chat/
│   ├── Terminal/
│   ├── Settings/
│   └── Shared/
├── Services/
│   ├── Index/                # CodebaseIndex (shared)
│   ├── Tools/                # AITool implementations (shared)
│   ├── LocalPipeline/        # Local 4B AI pipeline
│   │   ├── LocalInteractionService.swift
│   │   ├── InlinePopoverService.swift
│   │   └── (trims existing InlineCompletion/)
│   ├── CloudPipeline/        # Cloud AI pipeline
│   │   ├── ConversationOrchestrator/
│   │   ├── RAGEngine/
│   │   ├── ToolLoopHandler.swift
│   │   └── QAReviewHandler.swift
│   ├── LocalModels/          # MLX model management
│   ├── OpenRouterAI/         # OpenRouter API client
│   ├── Session/
│   ├── Errors/
│   ├── Logging/
│   └── Events/
├── Highlighting/
├── Markdown/
└── Utilities/
```

## Migration Log (What Was Actually Done)

The refocus branch (`refocus-v1`) executed a 5-phase migration (plus later Gemma 4 E4B model swap) over commits totalling 98 files changed, 2,395 added, 8,069 deleted. Below is the record of what was done so recovery from any pivot is possible.

### Phase 0 — Foundation (Cuts)
| What | Details |
|------|---------|
| Deleted Scoring/ | `Services/Index/Scoring/` — SwiftHeuristicScorer, QualityScoringEngine |
| Deleted AIEnrichment + events + DB manager | `Services/Index/AIEnrichment.swift`, `AIEnrichmentEvent.swift`, `AIEnrichmentDatabaseManager.swift` |
| Deleted RAGStatusGauge | `Components/RAGStatusGauge.swift` |
| Removed from CodebaseIndexProtocol | `aiEnrichedResourceCount`, `averageAIQualityScore`, `performAIEnrichment` |
| Removed from DatabaseManager | `isResourceAIEnriched`, `getAIEnrichedResourceCountScoped`, `getAverageAIQualityScoreScoped` (return 0) |
| Removed from ProjectCoordinator | AI enrichment scheduling references |
| Removed from DependencyContainer | AI enrichment registrations |
| Removed from AppState | enrichmentState, aiEnrichmentService |
| Fixed 6 test mocks | Updated mock implementations to match protocol changes |

### Phase 1 — Pipeline Isolation
| What | Details |
|------|---------|
| RAG removed from local path | `AIInteractionCoordinator.SendMessageWithRetryRequest` skips RAG when `usesLocalModel == true` |
| Orchestration removed from local path | `ConversationSendCoordinator.executeConversationFlow()` skips graph for local, direct LLM call |
| Unreachable path | Both land in `ToolLoopHandler` path — harmless for cloud, unreachable for local |

### Phase 2 — Structural Reorg
| What | Details |
|------|---------|
| `ConversationFlow/` → `CloudPipeline/` | Directory rename with Xcode 16 `fileSystemSynchronizedGroups` |
| `InlineCompletion/` → `LocalPipeline/InlineCompletion/` | Moved under local pipeline |
| `LocalInteractionService` | Created at `Services/LocalPipeline/LocalInteractionService.swift` |
| `LocalModelAdapter` + `Qwen36Adapter` | Created at `Services/LocalPipeline/` (later deleted — replaced by Gemma 4 E4B with native `toolCallFormat: .gemma` in `LocalModelCatalog`, no adapter needed) |
| `CompletionBenchmarkService` | Created at `Services/LocalPipeline/CompletionBenchmarkService.swift` |

### Phase 3 — Architecture Completion
| What | Details |
|------|---------|
| `SessionManager` | Extracted from `ConversationManager` (981→880 lines) |
| `AIRouter` | `Services/AIRouter.swift` — central dispatch for local/cloud routing |
| `RAGTelemetryAggregator` | Deleted |
| `CompletionContextAssembler` | `.fast` limits as default (prefix 4K→500, output 120→40 chars) |

### Phase 4 — Model Optimization (Migrated to Gemma 4 E4B)
| What | Details |
|------|---------|
| Model swap | Replaced Qwen3.6 target with `mlx-community/gemma-4-e4b-it-4bit@62b0e4e` (Gemma 4 E4B IT 4bit) |
| `LocalModelAdapter` protocol | 6 methods — **deleted** (unused; Gemma 4's native `.gemma` tool call format in `LocalModelCatalog` eliminates adapter pattern) |
| `Qwen36Adapter` | **Deleted** — replaced by gemma4 `normalizedRuntimeConfigData` shim in `LocalModelFileStore` |
| `LocalModelCatalog` | E4B context length set to 131072 (128K); `toolCallFormat: .gemma` |
| `LocalModelFileStore` | Removed spurious Gemma-2 runtime compat fields (`attn_logit_softcapping`, `query_pre_attn_scalar`, `rope_theta`) |
| `LocalModelProcessAIService` | Removed hardcoded gemma-4 TurboQuant disable; both KV cache types now work correctly |
| `test_gemma.swift` | Replaced with proper inference test script `test_gemma4_local.py` |
| 12B rejected | `gemma-4-12b-it-4bit` — `gemma4_unified` model type unsupported in vendored mlx-swift-lm; memory-marginal on 16GB M4 (~11-12 GB) |

## Syntax Highlighting (Neon + Tree-sitter)

The syntax highlighting engine lives in `Packages/SyntaxHighlighting/` — a local SPM wrapper depending on `ChimeHQ/Neon` and `CodeEditApp/CodeEditLanguages` (35+ tree-sitter grammars bundled as a single xcframework).

### Architecture

```
NSTextView
  └─ Neon.TextViewHighlighter          [attached by TreeSitterHighlightService]
       ├─ TreeSitterClient             [incremental parsing via SwiftTreeSitter]
       │    └─ LanguageConfiguration   [parser + highlights.scm queries per language]
       └─ TokenAttributeProvider       [maps capture names → NSAttributedString attributes]
            └─ switch on token.name    [defined in TreeSitterHighlightService.swift]
```

### How coloring works

1. Neon's `TextViewHighlighter` attaches to `NSTextView` and becomes the `NSTextStorage` delegate.
2. On text change, `TreeSitterClient` incrementally re-parses only the affected ranges.
3. The parsed tree is matched against `highlights.scm` queries (bundled per-language by `CodeEditLanguages`).
4. Each query match produces a `Token` with a `.name` (the capture name, e.g. `"keyword"`, `"type"`, `"function"`).
5. The `TokenAttributeProvider` closure maps `token.name` to a dictionary of `NSAttributedString.Key` attributes (foreground color, font, etc.).

All languages share the **same** `TokenAttributeProvider` — the coloring is capture-name-based, not language-based. A `@keyword` capture in Swift, Python, and TypeScript all get the same color. This keeps the scheme uniform and simple.

### Customizing the color scheme

Edit `TreeSitterHighlightService.swift` in `Packages/SyntaxHighlighting/Sources/SyntaxHighlighting/`.

The `attributeProvider` closure is a large `switch` on `token.name`. Each `case` maps a capture name prefix to a color:

```swift
private static let attributeProvider: TokenAttributeProvider = { token in
    var attrs: [NSAttributedString.Key: Any] = [:]
    switch token.name {
    case let s where s.hasPrefix("keyword"):
        attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)  // blue
    case let s where s.hasPrefix("type") || s.hasPrefix("type_") || s.hasPrefix("predefined_type"):
        attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)  // teal
    // ... add more cases here
    default:
        attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xDC)  // light gray
    }
    return attrs
}
```

**To figure out what `token.name` values your language produces:**

1. Enable the debug log by uncommenting the `print` in the `default` case:
   ```swift
   default:
       print("[token] \(token.name)")  // log unknown capture names
       attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xDC)
   ```
2. Open a file in that language and watch the console output.
3. Add new `case` entries for any discoverd capture names that need distinct coloring.

You can also use the `range` property on `Token` to see the exact character range if needed.

### Per-language customization (advanced)

If you need language-specific coloring beyond what capture names provide, you can inspect `token.name` for language-specific patterns. For example, TypeScript's grammar produces captures like `"type_identifier"` and `"predefined_type"` that don't follow the common `@type.*` convention:

```swift
case "type_identifier", "predefined_type":
    attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)
```

### Adding a new language grammar

Currently supported languages are defined by `CodeEditLanguages` (35+ grammars bundled via `CodeLanguagesContainer.xcframework`). No action is needed to add a new language if it's already in CodeEditLanguages — the grammar's `highlights.scm` query file is automatically loaded.

To add a language *not* supported by CodeEditLanguages, you would need to:

1. Add the tree-sitter grammar as an SPM dependency in `Packages/SyntaxHighlighting/Package.swift`
2. Add the language mapping in `TreeSitterHighlightService.resolveCodeLanguage()`
3. The grammar's `highlights.scm` must be bundled in its SPM resources

### Phase 5 — Polish (3/5 Complete)
| What | Details |
|------|---------|
| **5.1 Inline AI Popover** | `InlineAIPopoverView` + `InlineAIPopoverManager` with `.disabled` singleton, glass material overlay on `CodeEditorView`, question input + streaming answer |
| **5.2 Cloud pipeline bugs** | `ConditionalToolLoopNode.handle()` passes `usesLocalModel` (was defaulting to `false`). Recursive `ToolLoopHandler.handleToolLoopIfNeeded()` passes `usesLocalModel` (same bug). QA review failures caught and logged instead of fatal |
| **5.3 HNSW Semantic Search** | `HNSWIndex.swift` — pure-Swift HNSW with binary heap, M=16, efConstruction=200, efSearch=50. Integrated into `DatabaseMemoryManager` and `DatabaseCodeChunkManager` with lazy rebuild |
| 5.4 Singletons (28) | ⬜ Remaining |
| 5.5 Force unwraps (~50+) | ⬜ Remaining |

### Critical Known Issues
1. **`IndexStats` still has `aiEnrichedResourceCount`/`averageAIQualityScore`** — always 0 since AIEnrichment deleted. Cosmetic only.
2. **28 singletons remain** — Phase 5.4 target
3. **~50+ force unwraps** — Phase 5.5 target
4. **SPM test target broken** — Pre-existing `EventSource` dependency on swift-nio/CNIOExtrasZlib
5. **Gemma 4 E4B in-tree `modelType` shim** — `LocalModelFileStore` rewrites `gemma4`→`gemma4_text` in a runtime compatibility directory. Fragile if upstream mlx-swift-lm adds native `gemma4_text` support (the shim would become unnecessary but harmless).

---

## Project Root Registry

### Purpose

`ProjectRootRegistry` (`Services/ProjectRootRegistry.swift`) is the app-wide single source of truth for the active project root directory. It eliminates fragmentation where ~30+ consumers independently stored or resolved the project path, each potentially getting stale or inconsistent values.

### Ownership

Only **one call site** may write to the registry:

- `WorkspaceLifecycleCoordinator.workspaceRootDidChange(to:)` — called when the user opens a folder, creates a project, or the directory is restored from `UserDefaults` on launch.

This ensures that the project root cannot be mutated from arbitrary places, guaranteeing consistency.

### Fan-out pattern

All consumers read from `ProjectRootRegistry.shared`:

| Consumer | How it reads |
|----------|-------------|
| **Terminal** (`NativeTerminalView`) | `@ObservedObject private var projectRootRegistry` — SwiftUI reactively observes changes; `SwiftTermView.updateNSView` sends `cd` to the running shell when the directory changes |
| **File tree** (`FileExplorerView`) | `context.workspace.currentDirectory` (indirectly, fed from `WorkspaceLifecycleCoordinator` → same change event) |
| **Sandboxing** (`PathValidator`) | Receives `projectRoot` at construction from `ConversationManager.projectRoot` (set via `updateProjectRoot` in `WorkspaceLifecycleCoordinator`) |
| **Codebase index** (`ProjectCoordinator`) | `configureProject(root:)` called from `WorkspaceLifecycleCoordinator` |
| **AI tools** (`ConversationToolProvider`) | `projectRootProvider` closure → `ConversationManager.projectRoot` (updated via `updateProjectRoot`) |
| **Sessions, logs, chat** | `updateProjectRoot` fan-out in `ConversationManager` |

### Thread safety

`ProjectRootRegistry` is `@MainActor` with `@Published private(set) var current`. The `@Published` property provides a Combine publisher (`$current`) that all `@MainActor` consumers can subscribe to safely.

### Terminal directory change handling

When the project root changes while a terminal shell is running, `SwiftTermView` sends a `cd "<new-path>"` command to the shell's stdin. This is non-disruptive — the shell remains running and its session state (history, exports, etc.) is preserved. The path is escaped for double quotes, backticks, and `$` to prevent shell injection.

### Adding a new consumer

```swift
import Combine

@MainActor
final class MyConsumer {
    private var cancellables = Set<AnyCancellable>()

    func startObserving() {
        // Read current value
        let root = ProjectRootRegistry.shared.current

        // Subscribe to changes
        ProjectRootRegistry.shared.$current
            .compactMap { $0 }
            .sink { newRoot in
                // React to change
            }
            .store(in: &cancellables)
    }
}
```
