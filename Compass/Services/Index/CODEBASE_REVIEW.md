# Codebase Review and Issues (Initial)

_Last updated: July 24, 2026 — Fixes implemented per proposal below_

## Summary

This document provides an architectural review of the codebase, with a focus on the `CodebaseIndex` subsystem and its major collaborators. It highlights the biggest issues and risks identified so far, along with actionable recommendations.

---

## Key Issues and Risks

### 1. Concurrency and Actor Isolation
- The use of both actors and detached tasks is good for scalability, but can introduce subtle bugs if actor isolation is accidentally violated. Passing references (`self`) into `Task.detached` can introduce concurrency hazards if those references are assumed to be actor-isolated.

### 2. Initialization State Management
- `CodebaseIndexInitializationState` only supports a single waiting continuation. If multiple callers await initialization at once, only the last one is resumed. This can leave callers hanging and should be improved to support multiple waiters.

### 3. Nonisolated Initializers
- The `CodebaseIndex` uses `nonisolated` initializers but has mutable, non-thread-safe fields. Ensure that all mutation after construction is either actor-isolated or otherwise safely synchronized.

### 4. @unchecked Sendable Usage
- The use of `@unchecked Sendable` for types like `CodebaseIndex` and `EventBus` disables compiler safety checks. This increases flexibility, but also means the developer is responsible for maintaining thread safety.

### 5. Combine Usage on Non-Main Threads
- In `EventBus`, `PassthroughSubject` is protected by `NSLock`, but using Combine publishers across multiple threads can be risky. Make sure Combine’s thread-safety assumptions are never violated.

### 6. Waiting for Async Operations in Initializers
- If async initialization in `CodebaseIndex` fails, but the instance is returned, callers may interact with a partially initialized object. Always document (and ideally enforce) the requirement to await readiness.

### 7. Resource Leaks and Cancellation
- `Task.detached` is used for long-running tasks. Ensure these are always cancelled/cleaned up properly to avoid resource leaks.

### 8. Deadlock Risk on Continuation Resumption
- Resuming continuations 'outside actor isolation' is noted in the code. Double-check that no actor state is accessed after resuming, to truly avoid deadlocks.

### 9. Error Handling in Background Tasks
- Errors in background tasks are often just logged, not surfaced. This can make failures silent and hard to diagnose.

---

## Recommendations

- Support multiple pending waiters in initialization state actor.
- Prefer stricter isolation over `@unchecked Sendable` where possible. Document invariants carefully.
- Ensure all async tasks are cancelled and references cleaned up properly.
- Clearly document and/or enforce required async waiting before using an index instance.
- Audit all mutable state for thread safety concerns.
- Expand error handling so critical failures are surfaced to the UI or users—not just logged.

---

## More Issues and Observations

### 10. Power Management and Activity Coordination
- The `AgentActivityCoordinator` manages power assertions and background work tokens. If tokens are leaked or not properly released, power assertions may remain active, causing battery drain or system performance issues.
- **Improvement:** Ensure tokens are always released, especially in all error and cancellation paths. Consider structured concurrency to manage lifetimes.

### 11. Background Work Governor and Resource Monitoring
- `BackgroundWorkGovernor` uses polling and environment variables to delay work under high stress (CPU, RAM, thermal). Tuning can be tricky, and latency or starvation may result if thresholds are imprecise.
- **Improvement:** Document tunables and consider exposing configuration for advanced usage.

### 12. Symbol Extraction and Regex-based Parsing
- `SymbolExtractor` uses regular expressions for multiple languages. This approach is fast but can miss edge cases, especially as languages evolve.
- **Improvement:** Consider language servers or AST-based parsing for critical languages where accuracy is required.

### 13. Reference Graph and PageRank
- The repo map system uses symbol names for nodes in a reference graph. Symbol name collisions or ambiguous references could pollute the results.
- **Improvement:** Prefer disambiguation using scope, qualified names, or file context.

### 14. Error Reporting and Crash Handling
- Errors and logs are often sent to files or printed, but not always surfaced to users. Critical failures may go unnoticed if not monitored.
- **Improvement:** Surface important errors to the UI or a health dashboard, and aggregate error metrics for diagnosis.

### 15. Resource and File IO Robustness
- File and directory operations do not always handle transient errors robustly (e.g., racing to create a directory, or parallel log writes).
- **Improvement:** Use retry logic, atomic file operations, and better error reporting for important file changes.

### 16. Testing and Mockability
- Use of singletons and statics in various systems (like `AgentActivityCoordinator.shared`) makes dependency injection and testing harder.
- **Improvement:** Prefer dependency injection for testability and modularity.

### 17. Scalability Limits in In-Memory Caches
- In-memory caches (like `MapCache`) lack strong eviction or memory limit controls. Large projects or long-running sessions could exhaust memory.
- **Improvement:** Consider cache eviction policies or disk-backed caches for large data.

### 18. Multi-language and Multi-platform Considerations
- Symbol extraction covers many languages, but some (e.g., JS, Python, PHP) have basic extraction that may miss important details.
- **Improvement:** Document support levels and offer extension points for richer language integration.

---

You are encouraged to add to this review as new issues are found or improvements are made.

---

## Comprehensive Fix Proposal

_Added: July 24, 2026 — based on codebase validation of the above issues._

This section proposes concrete fixes for each validated issue, ordered by impact. Every proposal
follows the project's existing architectural patterns (actors, EventBus, protocol-based DI,
shared singletons where appropriate, `@unchecked Sendable` with documented invariants).

---

### P0 Fixes (Confirmed Bugs)

#### Fix 2: `CodebaseIndexInitializationState` — Support multiple waiters

**File:** `CodebaseIndex.swift`

**Problem:** A single `continuation` property means concurrent callers to `awaitInitialization()`
overwrite each other. The last waiter wins; earlier ones hang forever.

**Solution:** Replace single continuation with an array. Resume all on completion/failure:

```swift
public actor CodebaseIndexInitializationState {
    public enum State: Sendable {
        case pending
        case initializing
        case initialized
        case failed(Error)
    }

    private var state: State = .pending
    private var continuations: [CheckedContinuation<Void, Error>] = []

    public func awaitInitialization() async throws {
        switch state {
        case .initialized:
            return
        case .failed(let error):
            throw error
        case .pending, .initializing:
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    func startInitializing() {
        state = .initializing
    }

    func complete() {
        state = .initialized
        let conts = continuations
        continuations = []
        for c in conts { c.resume() }
    }

    func fail(_ error: Error) {
        state = .failed(error)
        let conts = continuations
        continuations = []
        for c in conts { c.resume(throwing: error) }
    }
}
```

**Rationale:** Arrays of continuations are the standard Swift concurrency pattern for
multi-waiter state machines. The actor guarantees exclusive access. Resuming outside
the actor (capture → nil → loop) prevents deadlocks — same approach as the original
code, now scaled to N waiters.

**Testing:** Add a test that calls `awaitInitialization()` from three concurrent Tasks,
verifies all three return after `complete()`, and that a fourth gets thrown after `fail()`.

---

#### Fix 13: Reference graph self-loop edge (RepoMapBuilder)

**File:** `SymbolExtractor.swift` — `RepoMapBuilder.buildMap()`

**Problem:** Line 448 creates `graph.addEdge(from: sourceNode, to: sourceNode)` — a self-loop
that contributes zero PageRank signal. The repo-map ranking is effectively random because no
cross-file dependency edges exist.

**Solution:** Create file-level nodes and edges from each file to the external symbols it references:

```swift
// Phase 2: build reference graph by scanning each file for symbols from OTHER files
var graph = ReferenceGraph()
// Register all symbol nodes
for node in allSymbolNames.values {
    graph.addNode(node)
}

// For each file, check which external symbols it references
for (filePath, content) in fileContentCache {
    // Create a file-level node representing this source file
    let fileNode = ReferenceGraph.Node(
        symbolName: "<file>",
        filePath: filePath,
        kind: "file"
    )
    graph.addNode(fileNode)

    let fileSymbols = Set(symbolsByFile[filePath]?.map { $0.name } ?? [])
    for extSym in allExternalSymbols where extSym.filePath != filePath {
        guard !fileSymbols.contains(extSym.symbolName) else { continue }
        // Simple substring check — acceptable tradeoff for speed
        guard content.contains(extSym.symbolName) else { continue }

        // Edge from this file TO the external symbol → "file depends on symbol"
        let targetNode = ReferenceGraph.Node(
            symbolName: extSym.symbolName,
            filePath: extSym.filePath,
            kind: extSym.kind
        )
        graph.addEdge(from: fileNode, to: targetNode)
    }
}
```

**Why file-level nodes?** The personalization vector is keyed by `filePath`
(see `personalizeFilePaths`). File-level nodes participate naturally in PageRank:
a file referenced in chat context gets a boost, which flows to the symbols it depends on.

**Also fix symbol-name collision** in Phase 1 (`allSymbolNames` keyed by `"\(kind)::\(name)"`):
change the key to include the defining file path so two files defining the same symbol name
don't collide. This also means adding the same symbol node only once per (file, symbol) pair,
which is the correct dedup behavior.

```swift
// In Phase 1, change the key to include filePath
let key = "\(sym.kind)::\(sym.name)::\(path)"
if allSymbolNames[key] == nil {
    allSymbolNames[key] = node
}
```

**Testing:** Write a unit test that builds a reference graph with two files (A.swift defines
`func helper()`, B.swift calls `helper()`), verifies the graph contains a file-level node for
B with an outgoing edge to `helper`'s node, and that PageRank ranks `helper` higher than
symbols not referenced cross-file.

---

### P1 Fixes (High Risk)

#### Fix 3+6: Nonisolated initializers and partial initialization

**File:** `CodebaseIndex.swift`

**Problem:** `CodebaseIndex` is `@unchecked Sendable` with `nonisolated init` and mutable
field `isEnabled`. The `createAsync` pattern returns an instance before `coordinator.start()`
completes, and errors from background initialization are not propagated.

**Solution (two-part):**

**Part A — Synchronize mutable state.** Wrap `isEnabled` in an OSAllocatedUnfairLock (or
continue using the existing pattern of accessing it only via the `IndexCoordinator` actor,
which already owns the authoritative copy). Document the invariant:

```swift
/// Thread safety: `isEnabled` is a local cache. The authoritative copy lives in
/// `coordinator` (an actor). Direct access to this field is safe for reads after
/// construction because it is only mutated via `setEnabled(_:)` which also updates
/// the coordinator. If concurrent mutation is ever needed, wrap in a lock.
```

Alternatively, remove `isEnabled` from `CodebaseIndex` entirely and route all enabled-checks
through `coordinator`:

```swift
public func setEnabled(_ enabled: Bool) {
    // Remove self.isEnabled = enabled — delegate entirely to coordinator
    Task { await coordinator.setEnabled(enabled) }
}

public var isEnabled: Bool {
    // If callers need this, add an async method
    get async { await coordinator.isEnabled }
}
```

**Part B — Propagate coordinator startup errors.** The detached task in `create()` currently
fires and forgets. Change to capture and propagate failures through `initializationState`:

```swift
public static func create(
    eventBus: EventBusProtocol,
    projectRoot: URL,
    aiService: AIService,
    config: IndexConfiguration = .default
) async throws -> CodebaseIndex {
    let index = CodebaseIndex.createAsync(
        eventBus: eventBus,
        projectRoot: projectRoot,
        aiService: aiService,
        config: config
    )

    // Start coordinator in background, propagate errors
    Task.detached(priority: .userInitiated) {
        do {
            await index.initializationState.startInitializing()
            try await index.coordinator.start(projectRoot: projectRoot)
            await index.initializationState.complete()
        } catch {
            await index.initializationState.fail(error)
        }
    }

    return index
}
```

This makes `await initializationState.awaitInitialization()` the single readiness barrier
that callers must pass before using the index — and it now correctly surfaces coordinator
failures.

**Caller-side enforcement:** Add a precondition or runtime check in every protocol method:

```swift
private func ensureReady() async throws {
    try await initializationState.awaitInitialization()
}
```

Call at the top of `start()`, `stop()`, `reindexProject()`, `searchSymbols()`, etc.

**Testing:** Write a test that creates a `CodebaseIndex` with a coordinator that throws on
`start()`, and verifies that `await initializationState.awaitInitialization()` rethrows the
expected error.

---

#### Fix 9: Surface errors from background tasks

**Files:** `IndexCoordinator.swift`, `CodebaseIndex+Lifecycle.swift`, `IndexerActor.swift`

**Problem:** Errors in `processIndexFiles`, `indexFile`, `cleanupStaleEntries` are logged
via `IndexLogger.shared.log()` but never surfaced to the user or UI. This creates silent
failures that make debugging indexing issues difficult.

**Solution:** Define a new event type and publish it on errors:

```swift
// In Core/DiagnosticsEvents.swift (or a new Core/IndexingErrorEvent.swift)
public struct IndexingErrorEvent: Event {
    public let operation: String
    public let filePath: String?
    public let errorDescription: String
    public let isCritical: Bool  // false → recoverable (single file), true → abort

    public init(operation: String, filePath: String? = nil, error: Error, isCritical: Bool = false) {
        self.operation = operation
        self.filePath = filePath
        self.errorDescription = error.localizedDescription
        self.isCritical = isCritical
    }
}
```

Publish at error sites:

```swift
// IndexCoordinator.processIndexFiles — per-file errors
do {
    try await indexer.indexFile(at: file)
    processed += 1
} catch {
    await IndexLogger.shared.log("Failed to index file \(file.path): \(error)")
    eventBus.publish(IndexingErrorEvent(
        operation: "indexFile",
        filePath: file.path,
        error: error
    ))
}

// IndexCoordinator.cleanupStaleEntries — non-critical
catch {
    await IndexLogger.shared.log("Failed to clean up stale entries: \(error)")
    eventBus.publish(IndexingErrorEvent(
        operation: "cleanupStaleEntries",
        error: error
    ))
}
```

**UI integration:** The status bar view (`IndexStatusBarViewModel.swift`) subscribes to
`IndexingErrorEvent` and shows a badge or toast for critical errors. This follows the
existing EventBus → UI pattern used by `IndexingProgressEvent` / `IndexingCompletedEvent`.

**Testing:** Add a harness check in `OfflineModeHarnessTests` that an `IndexingErrorEvent`
is published when indexing a deliberately broken file.

---

### P2 Fixes (Medium Risk)

#### Fix 4: @unchecked Sendable — document invariants

**Files:** `CodebaseIndex.swift`, `EventBus.swift`, `AgentActivityCoordinator.swift`, etc.

**Problem:** `@unchecked Sendable` disables compiler safety checks without documenting what
makes the type safe.

**Solution:** Add a `// Thread safety:` comment above each `@unchecked Sendable` conformance,
stating the invariant:

```swift
// Thread safety: all mutable state is either:
//   - actor-isolated (IndexCoordinator, initializationState)
//   - protected by NSLock (EventBus.subjects, AgentActivityCoordinator.activitiesByType)
//   - initialized once in init and read-only thereafter (database, projectRoot, etc.)
// The nonisolated init is safe because mutation only occurs after the instance is
// returned, at which point callers must await initializationState.awaitInitialization(),
// and subsequent mutations go through actor-isolated paths.
public class CodebaseIndex: CodebaseIndexProtocol, @unchecked Sendable {
```

```swift
// Thread safety: `subjects` dictionary is protected by `lock`. All published values
// are delivered on DispatchQueue.main via `.receive(on:)`.
public final class EventBus: EventBusProtocol, @unchecked Sendable {
```

**No behavioral change** — just documentation that makes the safety argument auditable.
This also makes future reviewers less likely to accidentally violate the invariant.

---

#### Fix 16: Reduce singleton coupling via protocol-based DI

**Files:** `IndexCoordinator.swift`, `AgentActivityCoordinator.swift`

**Problem:** `IndexCoordinator` defaults to `AgentActivityCoordinator.shared` and
`BackgroundWorkGovernor.shared` when no instance is passed. This makes unit testing
harder because the coordinator always uses the live shared instances.

**Solution:** The existing protocol-based design (`AgentActivityCoordinating`) is already
correct. The issue is that `IndexCoordinator`'s `init` silently falls back to `.shared`,
subverting DI.

Change `init` to require explicit injection, removing the fallback:

```swift
public init(
    eventBus: EventBusProtocol,
    indexer: IndexerActor,
    config: IndexConfiguration = .default,
    projectRoot: URL? = nil,
    activityCoordinator: any AgentActivityCoordinating  // required, no default
    backgroundWorkGovernor: BackgroundWorkGovernor       // required, no default
) {
    self.eventBus = eventBus
    self.indexer = indexer
    self.config = config
    self.isEnabled = config.enabled
    self.projectRoot = projectRoot?.standardizedFileURL
    self.activityCoordinator = activityCoordinator
    self.backgroundWorkGovernor = backgroundWorkGovernor
}
```

Update the call site in `CodebaseIndex`:

```swift
self.coordinator = IndexCoordinator(
    eventBus: eventBus,
    indexer: indexer,
    config: resolvedConfig.configuration,
    projectRoot: projectRoot,
    activityCoordinator: AgentActivityCoordinator.shared,
    backgroundWorkGovernor: .shared
)
```

**Testing benefit:** Test code can pass mocked `AgentActivityCoordinating` and
`BackgroundWorkGovernor` instances without workarounds. No behavioral change for
production.

---

#### Fix 17: MapCache — add memory cap with LRU eviction

**File:** `SymbolExtractor.swift` — `MapCache`

**Problem:** TTL-only eviction (5 min) means the cache grows unbounded for large projects
or long sessions. Each cached entry is the full repo-map text (~1000 tokens ≈ 4KB).

**Solution:** Add a maximum entry count with LRU eviction. The actor provides thread safety:

```swift
private actor MapCache {
    var cache: [String: String] = [:]
    var accessOrder: [String] = []  // most-recently accessed at the end
    let maxAge: TimeInterval = 300
    let maxEntries: Int = 50        // ~200KB worst case, negligible in practice

    func get(_ key: String) -> String? {
        guard let cached = cache[key], let age = cacheAge[key],
              Date().timeIntervalSince(age) < maxAge else { return nil }
        bumpAccess(key)
        return cached
    }

    func set(_ key: String, value: String) {
        if cache.count >= maxEntries && cache[key] == nil {
            // Evict least-recently used (front of accessOrder)
            if let oldest = accessOrder.first {
                cache.removeValue(forKey: oldest)
                cacheAge.removeValue(forKey: oldest)
                accessOrder.removeFirst()
            }
        }
        cache[key] = value
        cacheAge[key] = Date()
        bumpAccess(key)
    }

    private func bumpAccess(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    func invalidate(projectRoot: URL) {
        let prefix = projectRoot.standardizedFileURL.path
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        cacheAge = cacheAge.filter { !$0.key.hasPrefix(prefix) }
        accessOrder = accessOrder.filter { $0.hasPrefix(prefix) }
    }
}
```

---

### P3 Fixes (Low Risk / Monitoring)

#### Fix 1: Detached task capture discipline

**Files:** `CodebaseIndex.swift`, `IndexCoordinator.swift`

**Problem:** `CodebaseIndex.create()` captures `index` strongly in a `Task.detached`.
While `CodebaseIndex` is `@unchecked Sendable`, the strong capture means the instance
cannot be deallocated until the detached task completes.

**Solution:** Use `[weak index]` capture:

```swift
Task.detached(priority: .userInitiated) { [weak index] in
    guard let index else { return }
    await index.coordinator.start(projectRoot: projectRoot)
}
```

This is consistent with how `IndexCoordinator` uses `[weak self]` throughout. No behavioral
change since the caller holds a strong reference to the returned index anyway — the weak
capture just prevents the background task from extending lifetime if the caller releases
the index.

---

#### Fix 5: EventBus — document Combine threading model

**File:** `EventBus.swift`

**Problem:** `PassthroughSubject.send()` is called inside `lock.lock()`/`unlock()`.
Combine's contract says `send()` is re-entrant for the same subject, but delivering
synchronously inside a lock could theoretically cause issues if a subscriber's callback
contends on the same lock.

**Solution:** This is low risk because `.receive(on: DispatchQueue.main)` transforms
synchronous delivery into an async dispatch. Document the reasoning:

```swift
// Thread safety: `subjects` dictionary is protected by `lock`. Calls to
// `subject.send(event)` happen while the lock is held, which is safe because
// Combine's PassthroughSubject.send() is thread-safe and re-entrant.
// The `.receive(on: DispatchQueue.main)` downstream ensures subscribers never
// block the publishing thread.
```

No code change needed.

---

#### Fix 7: Track the fire-and-forget coordinator start task

**File:** `CodebaseIndex.swift` — `create()` method

**Problem:** The `Task.detached` that starts the coordinator has no reference stored,
so it cannot be cancelled if the index is stopped before initialization completes.

**Solution:** Store the task as a property and cancel it in `stop()`:

```swift
// In CodebaseIndex class:
private var coordinatorStartTask: Task<Void, Never>?

// In create():
let task = Task.detached(priority: .userInitiated) { ... }
index.coordinatorStartTask = task

// In stop():
coordinatorStartTask?.cancel()
coordinatorStartTask = nil
```

---

#### Fix 15: File IO — persistent file handle for loggers

**Files:** `IndexLogger.swift`, `AppLogger.swift`, `CrashReporter.swift`

**Problem:** Three loggers use the open-write-close pattern per log line.
This is inefficient and can cause race conditions under concurrent writes.

**Solution:** Switch to a persistent `FileHandle` opened once in `setup()`:

```swift
// In IndexLogger (actor — guarantees serialized access):
private var logHandle: FileHandle?

public func setup(projectRoot: URL) {
    // ... create directory and file as before ...
    self.logHandle = try FileHandle(forWritingTo: fileURL)
    try logHandle?.seekToEnd()
}

public func log(_ message: String) {
    // ... format message ...
    guard let handle = logHandle else { return }
    do {
        try handle.write(contentsOf: data)
    } catch {
        print("[IndexLogger] Write error: \(error)")
    }
}
```

Because `IndexLogger` is an actor, all log writes are serialized — no race possible.
Apply the same pattern to `AppLogger.swift` and `CrashReporter.swift`.

---

### Summary of Implementation Order

| Priority | Fix | Effort | File(s) |
|---|---|---|---|
| P0 | #2 Multi-waiter initialization state | Small | `CodebaseIndex.swift` |
| P0 | #13 Reference graph self-loop + name collision | Medium | `SymbolExtractor.swift` |
| P1 | #3+6 Nonisolated init + error propagation | Medium | `CodebaseIndex.swift`, `CodebaseIndex+Startup.swift`, `CodebaseIndex+Lifecycle.swift` |
| P1 | #9 Error surfacing via EventBus | Medium | `IndexCoordinator.swift`, new `Core/IndexingErrorEvent.swift` |
| P2 | #4 Document @unchecked Sendable invariants | Small | All `@unchecked Sendable` sites |
| P2 | #16 Protocol-based DI for IndexCoordinator | Small | `IndexCoordinator.swift`, `CodebaseIndex.swift` |
| P2 | #17 MapCache LRU eviction | Small | `SymbolExtractor.swift` |
| P3 | #1 Weak capture in detached task | Trivial | `CodebaseIndex.swift` |
| P3 | #5 Document Combine threading | Trivial | `EventBus.swift` |
| P3 | #7 Track coordinator start task | Small | `CodebaseIndex.swift` |
| P3 | #15 Persistent FileHandle for loggers | Small | `IndexLogger.swift`, `AppLogger.swift`, `CrashReporter.swift` |

### Fixes not in scope (deferred)

- **#12 Regex-based parsing** → AST/language-server parsing is a large, independent effort.
  Document known limitations as a tracking issue.
- **#18 Multi-language coverage** → Part of the same effort as #12.
- **#14 Error dashboard** → A UI-level feature that should be designed holistically with
  the diagnostics panel. The immediate fix from #9 (EventBus publishing) provides
  the data layer; the UI can be added later.
- **#10 Power assertion tokens** → The current `deinit`-safety-net pattern is sound.
  Revisit if battery drain reports emerge.
- **#11 BackgroundWorkGovernor tuning** → Already env-var tunable. Document
  `COMPASS_BACKGROUND_WORK_*` variables in `AGENTS.md`.

