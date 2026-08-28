# UI Blocking Issues - Comprehensive Analysis and Fix Plan

## Executive Summary

The application has critical UI blocking issues during startup and operation. The root causes are:

1. **Synchronous initialization** of heavy services on the main thread
2. **Synchronous database operations** using `queue.sync` that block callers
3. **CoreML model loading** happening synchronously during initialization
4. **Missing async boundaries** between UI and background work

This document provides a systematic analysis and actionable fix plan.

---

## Critical Issues Identified

### 1. DatabaseManager - Synchronous Blocking (CRITICAL)

**Location:** [`DatabaseManager.swift:326-332`](compass/Services/Index/Database/DatabaseManager.swift:326)

```swift
internal func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) == queueID {
        return try work()
    }
    return try queue.sync {  // ⚠️ BLOCKS CALLING THREAD
        try work()
    }
}
```

**Problem:** All database operations use `queue.sync` which blocks the calling thread. When called from `@MainActor` contexts, this blocks the UI.

**Impact:** Every database query, insert, update blocks the main thread.

**Fix:**
```swift
// Convert to async actor-based approach
actor DatabaseStore {
    private let database: DatabaseManager
    
    func getResourceLastModified(resourceId: String) throws -> Double? {
        // Already on actor's queue, no sync needed
        try database.getResourceLastModified(resourceId: resourceId)
    }
}
```

---

### 2. DependencyContainer Initialization (CRITICAL)

**Location:** [`DependencyContainer.swift:17-85`](compass/Services/DependencyContainer.swift:17)

```swift
init(isTesting: Bool = ...) {
    // ... creates all services synchronously ...
    
    if !isTesting, let root = _workspaceService.currentDirectory {
        _conversationManager.updateProjectRoot(root)  // ⚠️ BLOCKS
        _projectCoordinator.configureProject(root: root)  // ⚠️ BLOCKS
    }
}
```

**Problem:** The container creates and initializes all services synchronously, including:
- `CodebaseIndex` (database creation, embedding model loading)
- `ConversationManager` (history loading)
- `ProjectCoordinator` (file watcher setup)

**Impact:** App launch is blocked until all services are fully initialized.

**Fix:**
```swift
@MainActor
class DependencyContainer {
    private var initializationTask: Task<Void, Never>?
    
    init(isTesting: Bool = ...) {
        // Create lightweight service stubs only
        setupServiceStubs()
        
        // Defer heavy initialization
        initializationTask = Task { [weak self] in
            await self?.initializeHeavyServices()
        }
    }
    
    private func initializeHeavyServices() async {
        // Initialize database, embedding models, etc. asynchronously
    }
}
```

---

### 3. CodebaseIndex Synchronous Initialization (CRITICAL)

**Location:** [`CodebaseIndex.swift:29-62`](compass/Services/Index/CodebaseIndex.swift:29)

```swift
init(eventBus: EventBusProtocol, projectRoot: URL, aiService: AIService, config: IndexConfiguration) throws {
    // ...
    self.database = try DatabaseStore(path: dbPath)  // ⚠️ BLOCKS
    self.memoryEmbeddingGenerator = MemoryEmbeddingGeneratorFactory.makeDefault(projectRoot: projectRoot)  // ⚠️ BLOCKS
    // ...
}
```

**Problem:** Database creation and embedding generator initialization happen synchronously.

**Impact:** Project opening is blocked until index is fully initialized.

**Fix:**
```swift
@MainActor
class CodebaseIndex: CodebaseIndexProtocol {
    private let initializationState = AsyncInitializationState()
    private let _database: DatabaseStore?
    
    var database: DatabaseStore {
        get async throws {
            try await initializationState.awaitInitialization()
            return _database!
        }
    }
    
    static func create(eventBus: EventBusProtocol, projectRoot: URL, aiService: AIService) async throws -> CodebaseIndex {
        let index = CodebaseIndex(eventBus: eventBus, projectRoot: projectRoot)
        
        // Initialize database off main thread
        let database = try await Task.detached(priority: .userInitiated) {
            try DatabaseStore(path: index.dbPath)
        }.value
        
        await index.setDatabase(database)
        return index
    }
}
```

---

### 4. CoreML Embedding Model Loading (HIGH)

**Location:** [`MemoryEmbeddingGenerator.swift:73-97`](compass/Services/Index/Memory/MemoryEmbeddingGenerator.swift:73)

```swift
public static func makeDefault(projectRoot: URL?) -> CoreMLTextEmbeddingGenerator? {
    for modelURL in defaultCandidates where FileManager.default.fileExists(atPath: modelURL.path) {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)  // ⚠️ BLOCKS
            // ...
        }
    }
}
```

**Problem:** CoreML model loading is synchronous and can take several seconds, especially on first run when the model needs to be compiled for NPU.

**Impact:** First app launch is significantly delayed.

**Fix:**
```swift
public static func makeDefault(projectRoot: URL?) async -> CoreMLTextEmbeddingGenerator? {
    await Task.detached(priority: .userInitiated) {
        // Load model off main thread
        for modelURL in defaultCandidates where FileManager.default.fileExists(atPath: modelURL.path) {
            if let generator = tryLoadModel(modelURL) {
                return generator
            }
        }
        return nil
    }.value
}
```

---

### 5. ProjectCoordinator.configureProject (HIGH)

**Location:** [`ProjectCoordinator.swift:38-78`](compass/Services/ProjectCoordinator.swift:38)

```swift
func configureProject(root: URL) {
    // ...
    do {
        let index = try CodebaseIndex(eventBus: eventBus, projectRoot: root, aiService: aiService)  // ⚠️ BLOCKS
        self.codebaseIndex = index
        index.start()
        // ...
    }
}
```

**Problem:** Creates `CodebaseIndex` synchronously, blocking the caller.

**Impact:** Opening a project blocks the UI.

**Fix:**
```swift
func configureProject(root: URL) async {
    currentProjectRoot = root
    
    // Start initialization in background
    Task.detached(priority: .userInitiated) { [weak self] in
        guard let self = self else { return }
        
        do {
            let index = try await CodebaseIndex.create(
                eventBus: self.eventBus,
                projectRoot: root,
                aiService: self.aiService
            )
            
            await MainActor.run {
                self.codebaseIndex = index
                index.start()
            }
        } catch {
            await MainActor.run {
                self.errorManager.handle(.unknown("Failed to initialize CodebaseIndex: \(error)"))
            }
        }
    }
}
```

---

### 6. EventBus Main Actor Isolation (MEDIUM)

**Location:** [`EventBus.swift:29`](compass/Core/EventBus.swift:29)

```swift
@MainActor
public final class EventBus: EventBusProtocol {
    // ...
}
```

**Problem:** EventBus is isolated to `@MainActor`, meaning all publish operations must run on main thread. Background tasks publishing events cause main thread hops.

**Impact:** Background operations that publish progress events cause main thread contention.

**Fix:**
```swift
// Make EventBus thread-safe but not main-actor isolated
public final class EventBus: EventBusProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var subjects: [String: Any] = [:]
    
    public nonisolated func publish<E: Event>(_ event: E) {
        let key = String(describing: E.self)
        lock.lock()
        defer { lock.unlock() }
        
        if let subject = subjects[key] as? PassthroughSubject<E, Never> {
            subject.send(event)
        }
    }
}
```

---

### 7. ConversationManager Initialization (MEDIUM)

**Location:** [`ConversationManager.swift:100-146`](compass/Services/ConversationManager.swift:100)

```swift
init(dependencies: Dependencies) {
    // ... service assignments ...
    
    initializeLogging(root: root)  // Could be async
    setupObservation()
    setupStreamingSubscriptions()
    startTraceLogging()  // Uses Task.detached - good
    configureLoggingStores(root: root)  // Uses Task.detached - good
}
```

**Status:** Partially fixed - some operations use `Task.detached`.

**Remaining Issues:**
- `initializeLogging` is synchronous
- `setupObservation` could potentially block

---

### 8. LocalModelDownloader (LOW - Already Async)

**Location:** [`LocalModelDownloader.swift:3`](compass/Services/LocalModels/LocalModelDownloader.swift:3)

```swift
actor LocalModelDownloader {
    func download(model: LocalModelDefinition, onProgress: @Sendable (Progress) -> Void) async throws {
        // Already async - good
    }
}
```

**Status:** Already properly async. No changes needed.

---

### 9. LocalModelProcessAIService (LOW - Already Async)

**Location:** [`LocalModelProcessAIService.swift:37`](compass/Services/LocalModels/LocalModelProcessAIService.swift:37)

```swift
actor LocalModelProcessAIService: AIService {
    // Already actor-isolated - good
}
```

**Status:** Already properly async. Model loading uses async methods.

---

## Architectural Fix Plan

### Phase 1: Async Initialization Pattern

Create a standardized async initialization pattern:

```swift
/// Protocol for services that require async initialization
protocol AsyncInitializable {
    associatedtype InitializedState
    
    var initializationState: AsyncInitializationState { get }
    
    func initialize() async throws
}

/// Tracks initialization state for async services
actor AsyncInitializationState {
    enum State {
        case pending
        case initializing
        case initialized
        case failed(Error)
    }
    
    private var state: State = .pending
    private var continuations: [CheckedContinuation<Void, Error>] = []
    
    func awaitInitialization() async throws {
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
    
    func complete() {
        state = .initialized
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
    
    func fail(_ error: Error) {
        state = .failed(error)
        continuations.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
    }
}
```

### Phase 2: Database Layer Async Conversion

Convert `DatabaseManager` to actor-based async pattern:

```swift
actor DatabaseStore {
    private let database: DatabaseManager
    
    init(path: String) async throws {
        // Initialize database off any actor
        self.database = try await Task.detached {
            try DatabaseManager(path: path)
        }.value
    }
    
    // All operations are naturally async due to actor isolation
    func getResourceLastModified(resourceId: String) throws -> Double? {
        try database.getResourceLastModified(resourceId: resourceId)
    }
}
```

### Phase 3: Service Container Refactor

Refactor `DependencyContainer` for lazy async initialization:

```swift
@MainActor
class DependencyContainer: ObservableObject {
    @Published private(set) var isInitialized = false
    @Published private(set) var initializationProgress: String = ""
    
    private let initializationQueue = AsyncInitializationQueue()
    
    init(isTesting: Bool) {
        // Create lightweight stubs immediately
        createServiceStubs()
        
        // Queue heavy initialization
        Task {
            await initializeServices()
        }
    }
    
    private func initializeServices() async {
        await initializationQueue.execute { [weak self] in
            await self?.initializeDatabase()
            await self?.initializeEmbeddingModels()
            await self?.initializeCodebaseIndex()
        }
        
        isInitialized = true
    }
}
```

### Phase 4: UI State Management

Add loading states to UI:

```swift
struct ContentView: View {
    @ObservedObject var container: DependencyContainer
    
    var body: some View {
        if container.isInitialized {
            MainAppView()
        } else {
            LoadingView(progress: container.initializationProgress)
        }
    }
}
```

---

## Implementation Priority

### P0 - Critical (Blocks UI on every launch)
1. Convert `DatabaseManager.syncOnQueue` to async
2. Make `DependencyContainer.init` non-blocking
3. Make `CodebaseIndex.init` async

### P1 - High (Blocks UI on first launch or project open)
4. Make `CoreMLTextEmbeddingGenerator.makeDefault` async
5. Make `ProjectCoordinator.configureProject` async

### P2 - Medium (Causes main thread contention)
6. Make `EventBus` non-MainActor isolated
7. Add progress reporting to initialization

### P3 - Low (Already partially async)
8. Review remaining synchronous operations in `ConversationManager`

---

## Testing Strategy

1. **Startup Time Measurement**
   - Measure time from app launch to first frame
   - Target: < 500ms to interactive UI

2. **Main Thread Block Detection**
   - Use Instruments Time Profiler
   - Look for `queue.sync` calls on main thread

3. **First Launch Experience**
   - Test with fresh install (no cached models)
   - Verify UI remains responsive during model download/compilation

---

## Code Changes Summary

| File | Change | Priority |
|------|--------|----------|
| `DatabaseManager.swift` | Convert to actor-based async | P0 |
| `DatabaseStore.swift` | Make all methods async | P0 |
| `DependencyContainer.swift` | Defer heavy init to async task | P0 |
| `CodebaseIndex.swift` | Async factory method | P0 |
| `MemoryEmbeddingGenerator.swift` | Async model loading | P1 |
| `ProjectCoordinator.swift` | Async project configuration | P1 |
| `EventBus.swift` | Remove @MainActor isolation | P2 |
| `ContentView.swift` | Add loading state | P2 |

---

## Conclusion

The root cause of UI blocking is the synchronous initialization pattern used throughout the codebase. The fix requires:

1. **Async-by-default** for all I/O and heavy operations
2. **Actor isolation** for thread-safe state management
3. **Lazy initialization** with progress reporting
4. **Event-driven architecture** for background-to-UI communication

Implementing these changes will ensure the UI remains responsive during startup and throughout the application lifecycle.
