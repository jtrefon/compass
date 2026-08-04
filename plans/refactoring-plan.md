# Refactoring Plan: compass Code Quality Improvements

## Overview

This plan addresses the architecture issues, code smells, and technical debt identified in the comprehensive code review. The refactoring will be done incrementally with tests run after each phase to ensure stability.

## Phase 1: Extract Shared Utilities (Low Risk)

### 1.1 Create ToolLoopUtilities.swift

Create a new file to hold shared utility functions duplicated across handlers.

**Location:** `compass/Services/ConversationFlow/ToolLoopUtilities.swift`

**Functions to extract:**
- `toolResultsSummaryText(_ toolResults: [ChatMessage]) -> String`
- `toolOutputText(from message: ChatMessage) -> String`
- `truncate(_ text: String, limit: Int) -> String`
- `toolCallSummaries(_ toolCalls: [AIToolCall]) -> [OrchestrationRunSnapshot.ToolCallSummary]`
- `toolResultSummaries(_ toolResults: [ChatMessage]) -> [OrchestrationRunSnapshot.ToolResultSummary]`
- `appendRunSnapshot(payload: RunSnapshotPayload) async`

**Files affected:**
- `ToolLoopHandler.swift` - Remove duplicated methods
- `QAReviewHandler.swift` - Remove duplicated methods
- `FinalResponseHandler.swift` - Remove duplicated methods
- `ConversationSendCoordinator.swift` - Remove duplicated methods

### 1.2 Create RunSnapshotPayloadBuilder

Extract the snapshot building logic into a dedicated utility.

---

## Phase 2: Define Constants (Low Risk)

### 2.1 Create ToolLoopConstants.swift

**Location:** `compass/Services/ConversationFlow/ToolLoopConstants.swift`

**Constants to define:**
```swift
enum ToolLoopConstants {
    // Iteration limits
    static let maxAgentIterations = 12
    static let maxChatIterations = 5
    
    // Stall detection thresholds
    static let maxRepeatedBatchCount = 2
    static let maxConsecutiveReadOnlyIterations = 3
    static let maxRepeatedReadOnlyBatchCount = 2
    static let maxConsecutiveEmptyResponses = 2
    static let maxRepeatedNoToolCallContentCount = 2
    
    // Timeouts (in nanoseconds)
    static let debounceDelayNanos: UInt64 = 100_000_000 // 100ms
    static let watchdogPollIntervalNanos: UInt64 = 200_000_000 // 200ms
    static let sessionSaveDelayNanos: UInt64 = 500_000_000 // 500ms
    static let projectCoordinatorReindexDelayNanos: UInt64 = 5_000_000_000 // 5s
    
    // Text limits
    static let toolOutputPreviewLimit = 400
    static let toolOutputFullLimit = 1200
    static let invocationPreviewLimit = 700
    static let invocationContentLimit = 1400
    static let commandPreviewLimit = 280
}
```

### 2.2 Create OrchestrationConstants.swift

**Location:** `compass/Services/Orchestration/OrchestrationConstants.swift`

```swift
enum OrchestrationConstants {
    static let maxGraphTransitions = 64
}
```

---

## Phase 3: Remove Debug Print Statements (Low Risk)

### 3.1 Replace print with proper logging

**File:** `ConversationSendCoordinator.swift`

Replace:
```swift
print("[SendDiagnostic] === Starting send for conversation \(request.conversationId.prefix(8)) ===")
```

With:
```swift
await AppLogger.shared.debug(
    category: .conversation,
    message: "send.started",
    context: AppLogger.LogCallContext(metadata: [
        "conversationId": String(request.conversationId.prefix(8)),
        "mode": request.mode.rawValue,
        "historyCount": historyCoordinator.messages.count
    ])
)
```

---

## Phase 4: Refactor AIService Protocol (Medium Risk)

### 4.1 Move convenience methods to protocol extension

**File:** `AIServiceProtocol.swift`

Change from:
```swift
public protocol AIService: Sendable {
    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse
    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse
    func explainCode(_ code: String) async throws -> String
    func refactorCode(_ code: String, instructions: String) async throws -> String
    func generateCode(_ prompt: String) async throws -> String
    func fixCode(_ code: String, error: String) async throws -> String
}
```

To:
```swift
public protocol AIService: Sendable {
    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse
    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse
}

extension AIService {
    func explainCode(_ code: String) async throws -> String { ... }
    func refactorCode(_ code: String, instructions: String) async throws -> String { ... }
    func generateCode(_ prompt: String) async throws -> String { ... }
    func fixCode(_ code: String, error: String) async throws -> String { ... }
}
```

### 4.2 Update implementations

Remove the convenience method implementations from:
- `OpenRouterAIService.swift`
- `LocalModelProcessAIService.swift`
- `ModelRoutingAIService.swift`

---

## Phase 5: Break Down ToolLoopHandler (High Risk)

### 5.1 Create ToolLoopStallDetector

**Location:** `compass/Services/ConversationFlow/ToolLoopStallDetector.swift`

**Responsibilities:**
- Detect repeated tool batch stalls
- Detect read-only tool loop stalls
- Detect repeated content stalls
- Detect empty response stalls
- Track stall-related state variables

**Methods:**
```swift
final class ToolLoopStallDetector {
    struct StallState {
        var consecutiveReadOnlyToolIterations: Int = 0
        var previousReadOnlyToolBatchSignature: String?
        var repeatedReadOnlyToolBatchCount: Int = 0
        var previousToolBatchSignature: String?
        var repeatedToolBatchCount: Int = 0
        var previousNoToolCallContentSignature: String?
        var repeatedNoToolCallContentCount: Int = 0
        var consecutiveEmptyToolCallResponses: Int = 0
    }
    
    func detectStall(toolCalls: [AIToolCall], state: inout StallState) -> StallType?
    func shouldStopForReadOnlyToolLoopStall(toolCalls: [AIToolCall], state: inout StallState) -> Bool
    func updateRepeatedNoToolCallContentState(response: AIServiceResponse, state: inout StallState) -> Bool
}
```

### 5.2 Create ToolLoopMessageBuilder

**Location:** `compass/Services/ConversationFlow/ToolLoopMessageBuilder.swift`

**Responsibilities:**
- Build tool failure recovery messages
- Build tool loop context messages
- Build step update instruction messages
- Build focused execution messages

### 5.3 Refactor ToolLoopHandler

After extracting utilities, the handler should focus on:
- Tool loop orchestration
- Coordinating between detector, message builder, and executors
- State transitions

---

## Phase 6: Update Tests

### 6.1 Update existing tests

- Update any tests that reference removed methods
- Add tests for new utility classes
- Update mock implementations if needed

### 6.2 Add new tests

- `ToolLoopUtilitiesTests.swift`
- `ToolLoopStallDetectorTests.swift`
- `ToolLoopConstantsTests.swift`

---

## Phase 7: Run Tests

### 7.1 Unit tests
```bash
xcodebuild test -scheme compass -destination 'platform=macOS'
```

### 7.2 Harness tests
```bash
xcodebuild test -scheme compass -destination 'platform=macOS' -only-testing:compassHarnessTests
```

---

## Execution Order

1. **Phase 1** - Extract shared utilities (safest, immediate benefit)
2. **Phase 2** - Define constants (safe, improves readability)
3. **Phase 3** - Remove debug prints (safe, cleanup)
4. **Phase 4** - Refactor AIService protocol (medium risk, test thoroughly)
5. **Phase 5** - Break down ToolLoopHandler (highest risk, do last)
6. **Phase 6** - Update tests (ongoing with each phase)
7. **Phase 7** - Run all tests (after each phase)

---

## Rollback Plan

Each phase should be committed separately. If tests fail:
1. Revert the specific commit
2. Analyze the failure
3. Fix and re-commit

---

## Success Criteria

- All existing tests pass
- All harness tests pass
- No new compiler warnings
- Code coverage maintained or improved
- Reduced code duplication (measurable)
