# Architecture Proposal: Eliminate `try!` Crash Hazard in SessionRegistry

## Problem Statement

`SessionRegistry.ensureStore()` at `SessionRegistry.swift:119-131` contains a **crash hazard** — a `try!` force-unwrap that terminates the process when `ConversationStreamStore.init` throws. This violates the principle that transient I/O failures (disk full, permission changes) must never crash the application.

```swift
// Current code — the guard-else retries the EXACT SAME operation
// with try! instead of try?, guaranteeing a crash on I/O failure
private func ensureStore(for sessionId: String) -> ConversationStreamStore {
    if let existing = stores[sessionId] { return existing }
    guard let store = try? ConversationStreamStore(fileURL: url(for: sessionId)) else {
        // ⚠️ This try! will fail identically to the try? above — it's a guaranteed crash
        let store = try! ConversationStreamStore(fileURL: url(for: sessionId))
        stores[sessionId] = store
        return store
    }
    stores[sessionId] = store
    return store
}
```

## Root Cause Analysis

The `guard let … try?` / `try!` fallback pattern is logically broken:
- `try?` catches the error and returns nil
- The `else` branch retries with **the exact same arguments** — same `url(for:)` output
- If `try?` failed (disk full, permissions), `try!` **will also fail**, but now as a fatal crash
- The code comment says "Fallback: create empty store at the correct path" but the fallback path is identical to the primary path

The `ConversationStreamStore.init(fileURL:)` throws only when `FileManager.default.createDirectory(at:withIntermediateDirectories:)` fails — a transient I/O condition.

## Impact Analysis

### Call Site Inventory

All production usage flows through `ConversationCoordinator`, which calls `registry.store(forSessionId:)` — NOT `activeStore()`. Critically, these call sites **already handle nil** correctly:

| Caller | Pattern | Already handles nil? |
|---|---|---|
| `submitUserMessage` | `store?.append(event)` | Yes |
| `commitAgentTurn` | `store?.append(event)` | Yes |
| `commitToolResult` | `store?.append(event)` | Yes |
| `commitSystemMessage` | `store?.append(event)` | Yes |
| `commitPlan` | `store?.append(event)` | Yes |
| `commitCheckpoint` | `store?.append(event)` | Yes |
| `allTurns` | `guard let store` → returns `[]` | Yes |
| `turns(after:)` | `guard let store` → returns `[]` | Yes |
| `compact` | `guard let store` → returns early | Yes |
| `autoCompactIfNeeded` | `guard let store` → returns early | Yes |

The only code that calls `ensureStore` (the crashing method) is `activeStore()` — which is called **only in tests** (8 call sites in `SessionRegistryTests.swift`). No production code calls `activeStore()`.

### Risk Assessment

| Scenario | Current behavior | After fix | Risk |
|---|---|---|---|
| Disk full during `createDirectory` | **App crashes** | Turn silently discarded, logged | Low — edge case |
| Permission denied on `.ide/chat/` | **App crashes** | Turn silently discarded, logged | Low — edge case |
| `.ide/` directory deleted at runtime | **App crashes** | Turn silently discarded, logged | Low — edge case |

"Silent discard" in all cases means the user's message is not persisted, but the app continues to function. Messages are also preserved in the streaming pipeline's in-memory buffer.

## Proposed Solution

### Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Return type | Return `nil` (not fallback store) | Consistent with existing `store(forSessionId:)` API; the coordinator already handles nil |
| Error type | New typed `SessionStoreError` (conforms to `LocalizedError`) | Provides structured error for logging; callers can pattern-match if needed |
| Logging | `AppLogger.shared.error()` before returning nil | Zero observability currently — adding logging is the minimum boy-scout improvement |
| Protocol change | `activeStore()` → `ConversationStreamStore?` | Aligns return type with `store(forSessionId:)`; makes the nil path explicit in the contract |
| `ensureStore` | Remove `try!`, match `store(forSessionId)` return type | Eliminates the crash; both private helpers become consistent |

### Rationale for Returning nil (vs Fallback Store)

Two alternatives were evaluated:

**Alternative A — Null-Object Fallback Store**: Create an ephemeral memory-only `ConversationStreamStore` that conforms to `ConversationLogRepository` but discards writes.

**Rejected because**:
- Adds ~30 lines of code for a path that should almost never be exercised
- Erases the failure — callers have no way to detect "disk is full" vs "working normally"
- Data would be lost on restart anyway (memory-only), so the user gets a false sense of durability
- The coordinator's `guard let store` pattern already exists; nil is the established idiom in this codebase

**Alternative B — Periodic Retry**: Store creation failure triggers a periodic retry via a timer.

**Rejected because**:
- Requires a timer, actor state, and lifecycle management — disproportionate complexity
- `ConversationCoordinator` already gracefully handles nil stores
- A future improvement can layer this on top of the nil-returning API without changing the contract

### Changed Files

```
SessionRegistry.swift      — fix ensureStore(), activeStore(); update protocol SessionRegistryProtocol
SessionStoreError.swift    — NEW: typed error domain
SessionRegistryTests.swift — update 8 call sites for optional activeStore()
```

### Detailed Changes

#### 1. `SessionStoreError.swift` (NEW)

```swift
/// Errors that can occur when creating or accessing a conversation stream store.
/// These are transient I/O failures — not fatal.
public enum SessionStoreError: LocalizedError, Sendable {
    case storeCreationFailed(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .storeCreationFailed(let url, let underlying):
            return "Cannot create conversation store at \(url.path): \(underlying.localizedDescription)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .storeCreationFailed:
            return "Check disk space and file permissions on the project directory."
        }
    }
}
```

#### 2. `SessionRegistry.swift` — Protocol & Implementation

**Protocol change** — return type narrows from concrete to optional:

```swift
public protocol SessionRegistryProtocol: Sendable {
    func activeStore() async -> ConversationStreamStore?   // was: ConversationStreamStore
    func store(forSessionId id: String) async -> ConversationStreamStore?  // unchanged
    // ... rest unchanged ...
}
```

**Implementation change** — remove the `try!`, return nil consistently:

```swift
// Before (crash hazard):
private func ensureStore(for sessionId: String) -> ConversationStreamStore {
    if let existing = stores[sessionId] { return existing }
    guard let store = try? ConversationStreamStore(fileURL: url(for: sessionId)) else {
        let store = try! ConversationStreamStore(fileURL: url(for: sessionId))
        stores[sessionId] = store
        return store
    }
    stores[sessionId] = store
    return store
}

// After (no crash hazard, consistent with store(forSessionId:)):
private func ensureStore(for sessionId: String) -> ConversationStreamStore? {
    if let existing = stores[sessionId] { return existing }
    do {
        let store = try ConversationStreamStore(fileURL: url(for: sessionId))
        stores[sessionId] = store
        return store
    } catch {
        AppLogger.shared.error(
            "Failed to create conversation store",
            metadata: ["session_id": sessionId, "path": url(for: sessionId).path, "error": error.localizedDescription]
        )
        return nil
    }
}
```

Note: Using explicit `do/catch` rather than `try?` so we can capture the error details for logging. This is better than silent failure.

#### 3. `SessionRegistryTests.swift` — Update 8 Call Sites

All 8 `await reg.activeStore()` calls need to handle the optional:

```swift
// Before:
let storeA = await reg.activeStore()
try await appendOne(store: storeA, text: "a1")

// After:
guard let storeA = await reg.activeStore() else {
    XCTFail("Expected active store for session-a")
    return
}
try await appendOne(store: storeA, text: "a1")
```

### Error Flow

```
ConversationStreamStore.init throws (disk full, permissions)
    │
    ├── ensureStore() catches (do/catch)
    │       │
    │       ├── AppLogger.shared.error("Failed to create conversation store", metadata)
    │       │
    │       ├── returns nil
    │       │       │
    │       │       ├── activeStore() returns nil
    │       │       └── store(forSessionId:) returns nil (already optional, unchanged)
    │       │
    │       └── ConversationCoordinator call sites:
    │               ├── store?.append(event)   → nil, skip (message lost, app lives)
    │               └── guard let store         → early return (existing pattern)
    │
    └── User sees: message not persisted, app continues functioning
```

### Testing Strategy

| Test | What it verifies | How |
|---|---|---|
| `test_storeCreationFailure_returnsNil` | `ensureStore()` returns nil when `ConversationStreamStore.init` throws | Inject a path that fails `createDirectory` (e.g., `/dev/null/invalid`) |
| `test_storeCreationFailure_logsError` | Error is logged via AppLogger | Use a spy logger or verify metadata |
| `test_activeStoreMirrorsStoreForSessionId` | Both methods return consistent results | Create a registry, verify both return nil for same failing path |
| `test_coordinatorGracefulDegradation` | Coordinator does not crash when store is nil | Registry with failing path → call `submitUserMessage` → verify no crash |
| Existing tests pass | No regression | All 8 `activeStore()` call sites updated to guard |

Note: `ConversationStreamStore.init` only throws on `createDirectory` — testing this specifically requires a path without write permission, which is platform-sensitive. The unit test should use a path with `/dev/null/` or a similarly constrained URL. If pure-unit testing is impractical, the test can verify the guard pattern by direct inspection of the `do/catch` block.

### Acceptance Criteria

1. **Zero crash**: `grep -rn 'try!' compass/Services/ --include='*.swift'` returns 0 matches in non-test, non-vendor code
2. **Observability**: `AppLogger.shared.error` is called before returning nil from `ensureStore()`
3. **Consistent API**: `activeStore()` and `store(forSessionId:)` both return `ConversationStreamStore?`
4. **Backward compatible at call sites**: All existing callers (8 test sites + 10 coordinator sites) compile without error
5. **Test coverage**: At least one test verifies nil-returning behavior under failure conditions
6. **Existing tests pass**: `./run.sh test` completes without regression

### Implementation Order

```
1. Create SessionStoreError.swift         → 10 min
2. Modify SessionRegistryProtocol/actor   → 10 min  (change return types + fix ensureStore)
3. Update SessionRegistryTests.swift      → 10 min  (guard let on 8 call sites)
4. Add nil-path test                      → 10 min
5. Verify build + tests                   → 5 min (./run.sh test)
                                 Total:  ~45 min
```

### Open Question: Transient Recovery

If the disk becomes available again (user frees space), the current design requires a new `startNewSession` or `switchSession` call to re-create the store. The existing `store(forSessionId:)` already lazy-creates on demand, so if the callers naturally trigger store access after the failure condition resolves, the store will be created on the next access. No additional recovery mechanism is needed for this phase.

If we want proactive recovery in the future (e.g., periodic retry with a banner dismissal), it can be added as a separate capability without changing the protocol or the fix proposed here.
