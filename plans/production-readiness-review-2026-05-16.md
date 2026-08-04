# Production Readiness Plan

**Date:** 2026-05-16
**Context:** Code review of compass identified 10 areas needing improvement before production release.
**Goal:** Bring the application closer to production readiness by addressing structural, safety, and quality gaps.

---

## Priority Legend

| Label | Meaning |
|---|---|
| **P0** | Blocking — safety or correctness issue, fix immediately |
| **P1** | High — structural debt impacting velocity or stability |
| **P2** | Medium — quality improvement, plan into next cycle |
| **P3** | Low — nice-to-have, schedule when convenient |

---

## P0 — Fix Immediately

### 1. Replace `unowned self` with `weak self` in ConversationManager

**File:** `compass/Services/ConversationManager.swift`, line 83

```swift
// BEFORE (crashes if deallocated during async work)
aiServiceProvider: { [unowned self] in self.aiService },

// AFTER
aiServiceProvider: { [weak self] in self?.aiService },
```

Also audit the rest of `ConversationManager` for any other `unowned` captures. The same pattern may exist elsewhere in the codebase — a single `rg` pass across the project is warranted:

```sh
rg '\[unowned self\]' compass/
```

**Effort:** 30 min
**Risk:** Low — straightforward replacement, existing tests should catch regressions.


### 2. Hardcoded `/tmp/compass-startup.log` — Add PID Isolation

**File:** `compass/Services/DependencyContainer.swift`, function `earlyDiag`, line 25

The hardcoded path `/tmp/compass-startup.log` will collide if two instances run simultaneously (e.g., test runner + dev build, or multi-user Mac). Include the PID:

```swift
let tmpLog = URL(fileURLWithPath: "/tmp/compass-startup-\(ProcessInfo.processInfo.processIdentifier).log")
```

**Effort:** 5 min
**Risk:** None


## P1 — Address in Current Cycle

### 3. Decompose DependencyContainer

**Files:** `compass/Services/DependencyContainer.swift` (539 lines)

**Problem:** The container is a god object — it constructs, holds, and manages lifecycle for every service in the app. The 150-line `init()` is hard to read, test, and modify.

**Plan:**

Phase A — Extract factory methods into separate files:
- `AIServicesFactory.swift` — move `makeAIServices()` and all AI provider construction
- `EditorServicesFactory.swift` — file editor, inline completion, diagnostics, linting
- `IndexServicesFactory.swift` — project coordinator, codebase index, enrichment

Phase B — Split the container itself:
- Keep `DependencyContainer` as a facade that composes sub-containers
- Create `AIServiceContainer`, `EditorServiceContainer`, `IndexServiceContainer`
- Each sub-container manages its own lifecycle and initialization

Phase C — Lazy initialization:
- Services that only need to exist when a project is open should be created in
  `ProjectCoordinator.configureProject()`, not at app launch
- `initializeHeavyServices()` should be the trigger for project-scoped services

**Effort:** 3–4 days
**Risk:** Medium — touches initialization path; existing unit tests should gate regressions. Do Phase A first, validate, then Phase B, then C.

### 4. Break Up ConversationManager

**Files:** `compass/Services/ConversationManager.swift` (likely 600+ lines)

**Problem:** Despite the `ConversationSendCoordinator` extraction, `ConversationManager` still manages: message CRUD, streaming rendering, session/tab switching, provider issue display, power management observation, 5+ event bus subscriptions, and preview state.

**Plan:**

Extract three new focused types:

| New Type | Responsibility |
|---|---|
| `ConversationSessionManager` | Tab CRUD, session snapshots, `currentSessionId`, `conversationTabs`, `switchTab()`, `newTab()`, `closeTab()` |
| `StreamingRenderer` | `activeStreamingRunId`, `draftAssistantMessageId`, `pendingStreamingBuffer`, `pendingReasoningBuffer`, `streamingRenderTask`, `dequeueStreamingDelta()`, `appendToLiveModelPreview()` |
| `ModelPreviewController` | `liveModelOutputPreview`, `liveModelOutputStatusPreview`, `isLiveModelOutputPreviewVisible`, max preview character caps |

`ConversationManager` then becomes a coordinator that delegates to these three types, keeping only the `sendMessage()` pipeline and the `@Published` surface the UI needs.

**Effort:** 2–3 days
**Risk:** Medium — refactoring a hot path. Add `ConversationManagerTests` coverage before extracting, then extract + verify.

### 5. Audit and Reduce EventBus Logging Overhead

**Files:** `compass/Core/EventBus.swift`, lines 40–48, 62–70

**Problem:** Every `publish()` and `subscribe()` call spawns a `Task` for debug logging. High-frequency events (streaming chunks, indexing progress) create thousands of short-lived Tasks.

**Plan:**

Option A (simpler) — Add a sampling rate:
```swift
private var publishCount: UInt64 = 0
private let logSampleRate: UInt64 = 100

public func publish<E: Event>(_ event: E) {
    let key = String(describing: E.self)
    let current = OSAtomicIncrement64(&publishCount)
    if current % logSampleRate == 0 {
        Task { await AppLogger.shared.debug(...) }
    }
    // ... subject.send(event) ...
}
```

Option B (better) — Use a dedicated logging actor with a ring buffer that flushes periodically, decoupling logging from event dispatch entirely.

Start with Option A, measure impact, escalate to Option B if needed.

**Effort:** 1–2 hours for Option A; 1 day for Option B
**Risk:** Low — logging changes only

### 6. Replace `[String: Any]` Tool Parameters with Codable

**Files:** `compass/Services/AITool.swift` and all tool implementations in `compass/Services/Tools/`

**Problem:** Every tool repeats the same guard-casting pattern:
```swift
guard let path = arguments["path"] as? String, ...
guard let content = arguments["content"] as? String else { ... }
```

This is error-prone, noisy, and bypasses compile-time checking.

**Plan:**

Step 1 — Define a `ToolParameter` protocol:
```swift
protocol ToolParameter: Codable {
    static var jsonSchema: [String: Any] { get }
}
```

Step 2 — Each tool defines its own parameter struct:
```swift
struct WriteFileParameters: ToolParameter {
    let path: String
    let content: String
    let mode: String?  // "apply" | "propose"
    let patch_set_id: String?

    static var jsonSchema: [String: Any] {
        // ... generated from CodingKeys or a macro
    }
}
```

Step 3 — Update `AITool` protocol:
```swift
protocol AITool: Sendable {
    associatedtype Parameters: ToolParameter
    var name: String { get }
    var description: String { get }
    func execute(parameters: Parameters) async throws -> String
}
```

Step 4 — `AIToolExecutor` decodes `ToolArguments` into `Parameters` once, and passes the typed struct to `execute()`.

Step 5 — Migrate tools incrementally, starting with the most-used ones (WriteFileTool, ReplaceInFileTool, ReadFileTool).

**Effort:** 3–5 days (design + first tools + validation)
**Risk:** Medium — architectural change to `AITool` protocol. Use `associatedtype` with type erasure (`AnyAITool`) for the executor so the change is non-breaking for existing tool consumers.

### 7. Expand Test Coverage for Critical Paths

**Current state:** 86 test files, 14,584 test LOC vs ~60,800 production LOC (~24% ratio)

**Priority targets for new tests:**

| Area | Why |
|---|---|
| `ToolLoopHandler` | Core agent loop — errors here break all AI functionality |
| `ToolExecutionCoordinator` | Orchestrates parallel/batch tool execution |
| `StreamingRenderer` (post-extraction) | Character batching, truncation, cancellation — subtle bugs |
| `ConversationFoldingService` | Data loss here means lost chat history |
| `WriteFileTool` edge cases | Empty content, binary content, permission denied, concurrent writes |
| `ReplaceInFileTool` edge cases | Partial match, multi-match, empty old_string, encoding issues |
| `CodebaseIndex` file watching | Touched-but-unchanged, rapid create-delete-create, symlinks |

**Effort:** Ongoing — target 2–3 new test files per cycle
**Risk:** Low — tests add safety, not risk

### 8. Add `// MARK: -` Organization to Large Files

**Target files (200+ lines without MARK sections):**

- `DependencyContainer.swift`
- `ConversationManager.swift`
- `ContentView.swift`
- `AIToolExecutor.swift`
- `CodeEditorTextView.swift`
- `ModernFileTreeCoordinator.swift`

**Standard to follow (from ErrorManager.swift, which already does this well):**
```swift
// MARK: - Public API
// MARK: - Private Helpers
// MARK: - Initialization
```

**Effort:** 2–3 hours across all files
**Risk:** None


## P2 — Plan for Next Cycle

### 9. Evaluate Swift Testing Framework for New Tests

`import Testing` is now mature on macOS 14+ / Xcode 17+. Benefits over XCTest:
- Parameterized tests (`@Test(arguments: ...)`)
- No setUp/tearDown — init/deinit with value semantics
- Cleaner async patterns
- Tags for test categorization

Keep XCTest for existing tests; write new test files using Swift Testing. No migration needed.

**Effort:** 1 hour to set up first test and document the pattern
**Risk:** None

### 10. Move `earlyDiag` into a Proper Diagnostic Service

The free function in `DependencyContainer.swift` writes to a hardcoded path with raw `FileHandle` operations. After the PID fix (P0 #2), move this into:
- A `StartupLogger` actor that can be disabled in release builds
- Configurable log path via `AppConstantsStorage`

This removes a free function floating at the top of a file and makes the startup diagnostics testable.

**Effort:** 1 day
**Risk:** Low

### 11. Add a `ConversationManagerProtocol` Coverage Check

`ConversationManagerProtocol` exists but it's not clear if all consumers go through the protocol or reach into `ConversationManager` directly. Audit all references:

```sh
rg 'ConversationManager' compass/ --no-filename | grep -v 'Tests/' | grep -v 'Protocol'
```

Any direct usage that could use the protocol instead is a coupling point. This matters for the P1 refactor — the more consumers use the protocol, the safer the extraction.

**Effort:** 2–3 hours
**Risk:** None


## Implementation Order

```
Week 1:
  P0 #1  — Replace unowned → weak (audit entire codebase)
  P0 #2  — Add PID to startup log path
  P1 #8  — Add MARK comments (quick win, improves navigability)
  P1 #5  — EventBus logging sampling (Option A)

Week 2:
  P1 #11 — Protocol coverage audit
  P1 #3  — Phase A: Extract factory methods from DependencyContainer
  P1 #7  — Start writing targeted tests (ToolLoopHandler, ToolExecutionCoordinator)

Week 3:
  P1 #4  — Extract ConversationSessionManager + StreamingRenderer
  P1 #3  — Phase B: Sub-containers

Week 4:
  P1 #6  — Design Codable tool params, migrate WriteFileTool + ReadFileTool
  P1 #7  — More edge-case tests

Week 5+:
  P1 #3  — Phase C: Lazy project-scoped services
  P1 #6  — Migrate remaining tools
  P2 #9  — Adopt Swift Testing for new tests
  P2 #10 — StartupLogger service extraction
```

---

## Success Criteria

- [ ] Zero `unowned self` captures in the codebase
- [ ] DependencyContainer init is under 80 lines
- [ ] ConversationManager is under 300 lines
- [ ] All 30+ tools use typed Codable parameters
- [ ] Test-to-production ratio reaches 30%+
- [ ] EventBus logging does not create Tasks on the hot path
- [ ] No hardcoded paths outside of `AppConstants`
- [ ] All files over 200 lines have MARK sections
- [ ] `./run.sh test` passes with no regressions after each phase
