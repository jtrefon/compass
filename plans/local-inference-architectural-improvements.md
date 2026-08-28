# Local Inference Architectural Improvements

## Executive Summary

Following the performance optimization work (quantization fix, prompt prefix caching), this document identifies architectural issues, code quality problems, and areas for improvement in the local inference subsystem.

---

## Issue Categories

### 1. Code Duplication (DRY Violations)

#### 1.1 Reasoning Prompt Duplication

**Problem:** The reasoning prompt is duplicated in two locations:
- [`LocalModelProcessAIService.swift:376-405`](compass/Services/LocalModels/LocalModelProcessAIService.swift:376)
- [`OpenRouterAIService+ChatPreparation.swift:145-174`](compass/Services/OpenRouterAI/OpenRouterAIService+ChatPreparation.swift:145)

**Impact:** Maintenance burden, risk of inconsistency

**Solution:** Extract to shared location
```swift
// Move to ToolAwarenessPrompt.swift or new ReasoningPrompt.swift
extension ToolAwarenessPrompt {
    static let reasoningPrompt = """
    ## Reasoning
    When responding, include a structured reasoning block...
    """
}
```

#### 1.2 System Content Building Duplication

**Problem:** Both services implement `buildSystemContent()` with similar logic:
- [`LocalModelProcessAIService.swift:349-374`](compass/Services/LocalModels/LocalModelProcessAIService.swift:349)
- [`OpenRouterAIService+ChatPreparation.swift:94-114`](compass/Services/OpenRouterAI/OpenRouterAIService+ChatPreparation.swift:94)

**Solution:** Create a shared `SystemContentBuilder` service

---

### 2. God Class: LocalModelProcessAIService

**Problem:** The [`LocalModelProcessAIService`](compass/Services/LocalModels/LocalModelProcessAIService.swift:1) actor has grown to 407 lines with multiple responsibilities:

| Responsibility | Lines | Should Be |
|---------------|-------|-----------|
| Memory pressure handling | 6-33 | Separate `MemoryPressureHandler` class |
| Model file storage protocol | 46-59 | Already exists as `LocalModelFileStore` |
| MLX generator actor | 65-152 | Separate file |
| Prompt building | 317-406 | Shared `PromptBuilder` |
| System content building | 349-374 | Shared `SystemContentBuilder` |
| Service orchestration | 202-267 | Keep in service |

**Recommended Refactor:**

```
Services/LocalModels/
├── LocalModelProcessAIService.swift    # Orchestration only (~100 lines)
├── NativeMLXGenerator.swift            # Extracted actor
├── MemoryPressureObserver.swift        # Extracted class
├── PromptPrefixCache.swift             # Already extracted ✓
├── LocalModelCatalog.swift             # Already clean ✓
├── LocalModelDownloader.swift          # Already clean ✓
├── LocalModelFileStore.swift           # Already clean ✓
└── PromptBuilder.swift                 # New shared component
```

---

### 3. Missing Abstractions

#### 3.1 Prompt Building Protocol

**Problem:** Prompt construction is scattered across services with no shared interface.

**Solution:** Create `PromptBuilding` protocol
```swift
protocol PromptBuilding {
    func buildSystemContent(
        systemPrompt: String,
        hasTools: Bool,
        mode: AIMode?,
        projectRoot: URL?,
        reasoningEnabled: Bool
    ) -> String
    
    func buildPrompt(
        messages: [ChatMessage],
        systemContent: String,
        context: String?
    ) -> String
}
```

#### 3.2 Model Lifecycle Management

**Problem:** Model loading, caching, and unloading are mixed with inference logic.

**Solution:** Create `ModelLifecycleManager` actor
```swift
actor ModelLifecycleManager {
    func loadModel(modelId: String) async throws -> ModelContainer
    func unloadModel(modelId: String)
    func unloadAllModels()
    var loadedModelId: String? { get }
}
```

---

### 4. Settings Duplication

**Problem:** Settings keys are duplicated between:
- [`LocalModelSelectionStore.swift:5-6`](compass/Services/LocalModels/LocalModelSelectionStore.swift:5)
- [`LocalModelSettingsViewModel.swift:41-42`](compass/Services/LocalModels/LocalModelSettingsViewModel.swift:41)

```swift
// LocalModelSelectionStore
private let selectedModelKey = "LocalModel.SelectedId"
private let offlineModeEnabledKey = "AI.OfflineModeEnabled"

// LocalModelSettingsViewModel
private let selectedModelKey = "LocalModel.SelectedId"
private let offlineModeEnabledKey = "AI.OfflineModeEnabled"
```

**Solution:** Create `LocalModelSettingsKeys` constants
```swift
enum LocalModelSettingsKeys {
    static let selectedModelId = "LocalModel.SelectedId"
    static let offlineModeEnabled = "AI.OfflineModeEnabled"
}
```

---

### 5. Protocol Design Issues

#### 5.1 AIService Protocol Convenience Methods

**Problem:** The [`AIService`](compass/Services/AIServiceProtocol.swift:1) protocol includes convenience methods that have identical implementations in all conforming types:

```swift
func explainCode(_ code: String) async throws -> String
func refactorCode(_ code: String, instructions: String) async throws -> String
func generateCode(_ prompt: String) async throws -> String
func fixCode(_ code: String, error: String) async throws -> String
```

**Solution:** Move to protocol extension
```swift
extension AIService {
    func explainCode(_ code: String) async throws -> String {
        let prompt = "Explain the following code in clear, concise terms:\n\n\(code)"
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: prompt, context: nil, tools: nil, mode: nil, projectRoot: nil
        ))
        return response.content ?? ""
    }
    // ... other methods
}
```

#### 5.2 Model File Storing Protocol Nested in Service

**Problem:** [`ModelFileStoring`](compass/Services/LocalModels/LocalModelProcessAIService.swift:46) is nested inside the service actor, making it inaccessible for testing/mocking.

**Solution:** Move to top-level protocol
```swift
// New file: LocalModelFileStoring.swift
protocol LocalModelFileStoring: Sendable {
    func isModelInstalled(_ model: LocalModelDefinition) -> Bool
    func modelDirectory(modelId: String) throws -> URL
}
```

---

### 6. Error Handling Improvements

**Problem:** Error messages are stringly-typed and inconsistent:
- `"No local model selected."`
- `"Selected local model is not recognized: \(modelId)"`
- `"Local model is not downloaded: \(model.displayName)"`

**Solution:** Create `LocalModelError` enum
```swift
enum LocalModelError: LocalizedError {
    case noModelSelected
    case modelNotRecognized(String)
    case modelNotDownloaded(String)
    case modelLoadFailed(String, underlying: Error)
    
    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No local model selected."
        case .modelNotRecognized(let id):
            return "Model not recognized: \(id)"
        case .modelNotDownloaded(let name):
            return "Model not downloaded: \(name)"
        case .modelLoadFailed(let name, let underlying):
            return "Failed to load model \(name): \(underlying.localizedDescription)"
        }
    }
}
```

---

### 7. Test Coverage Gaps

**Missing Tests:**
- `NativeMLXGenerator` actor (currently only tested via integration tests)
- `LocalModelDownloader` error scenarios
- `LocalModelFileStore` config parsing
- Memory pressure handling

**Recommended Additions:**
```
compassTests/
├── LocalModels/
│   ├── NativeMLXGeneratorTests.swift
│   ├── LocalModelDownloaderTests.swift
│   ├── LocalModelFileStoreTests.swift
│   └── PromptPrefixCacheTests.swift  # Already exists ✓
```

---

### 8. Performance Monitoring Improvements

**Current State:** Performance metrics exist but are not integrated into the service.

**Recommendations:**
1. Add `InferenceMetricsRecorder` protocol to `LocalModelProcessAIService`
2. Emit metrics events via `EventBus` for aggregation
3. Add metrics to `LocalModelSettingsViewModel` for UI display

```swift
protocol InferenceMetricsRecording: Sendable {
    func recordTimeToFirstToken(_ duration: TimeInterval)
    func recordTokensPerSecond(_ rate: Double)
    func recordInferenceComplete(metrics: InferenceMetrics)
}
```

---

## Implementation Priority

### Phase 1: Quick Wins (Low Risk)
1. ✅ Extract reasoning prompt to `ToolAwarenessPrompt`
2. ✅ Create `LocalModelSettingsKeys` constants
3. ✅ Move `AIService` convenience methods to protocol extension

### Phase 2: Structural Improvements (Medium Risk)
4. Extract `NativeMLXGenerator` to separate file
5. Extract `MemoryPressureObserver` to separate file
6. Create `LocalModelError` enum
7. Create shared `PromptBuilder` service

### Phase 3: Architectural Refactoring (Higher Risk)
8. Create `ModelLifecycleManager` actor
9. Create `SystemContentBuilder` protocol
10. Add comprehensive unit tests

---

## File Changes Summary

| File | Action | Priority |
|------|--------|----------|
| `ToolAwarenessPrompt.swift` | Add reasoning prompt | P1 |
| `LocalModelSettingsKeys.swift` | Create new | P1 |
| `AIServiceProtocol.swift` | Add protocol extension | P1 |
| `NativeMLXGenerator.swift` | Extract from service | P2 |
| `MemoryPressureObserver.swift` | Extract from service | P2 |
| `LocalModelError.swift` | Create new | P2 |
| `PromptBuilder.swift` | Create new | P2 |
| `ModelLifecycleManager.swift` | Create new | P3 |
| `LocalModelProcessAIService.swift` | Refactor to orchestration | P3 |

---

## Metrics

### Current State
- `LocalModelProcessAIService.swift`: 407 lines (target: ~150 lines)
- Code duplication: ~80 lines of duplicated prompt building
- Test coverage: Limited unit tests for local models

### Target State
- Service files: < 200 lines each
- Zero code duplication for prompt building
- Comprehensive unit test coverage (>80%)

---

## Next Steps

1. Review and approve this plan
2. Switch to Code mode for implementation
3. Start with Phase 1 quick wins
4. Run tests after each phase
