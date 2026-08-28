# Agent Panel Investigation and Cleanup Plan

## Executive Summary

The agent panel implementation has several architectural issues causing UI glitching and functionality problems where agent requests start, run token generation, then stop without rendering in chat history.

## Identified Issues

### Issue 1: State Propagation Chain Complexity

**Location:** [`ChatHistoryManager.swift`](compass/Services/ChatHistoryManager.swift), [`ChatHistoryCoordinator.swift`](compass/Services/ChatHistoryCoordinator.swift), [`ConversationManager.swift`](compass/Services/ConversationManager.swift)

**Problem:** There's a complex chain of state propagation:
1. `ChatHistoryManager` is an `@MainActor ObservableObject` with `@Published var messages`
2. `ChatHistoryCoordinator` wraps `ChatHistoryManager` but doesn't forward `objectWillChange`
3. `ConversationManager` manually observes `historyManager.objectWillChange` and forwards it

**Code Flow:**
```
ChatHistoryManager.@Published messages 
  → (manual observation in ConversationManager.setupObservation)
  → ConversationManager.objectWillChange
  → AIChatPanel.onReceive(conversationManager.statePublisher)
  → refreshTick &+= 1 (workaround)
```

**Issues:**
- The `ChatHistoryCoordinator` is a pass-through that adds no value but adds complexity
- Manual observation setup is fragile and duplicates SwiftUI's built-in observation
- The `refreshTick` workaround in [`AIChatPanel.swift:107-111`](compass/Components/AIChatPanel.swift:107) indicates the normal observation isn't working properly

### Issue 2: Draft Message Handling During Streaming

**Location:** [`ConversationManager.swift:152-177`](compass/Services/ConversationManager.swift:152), [`ChatHistoryManager.swift:39-45`](compass/Services/ChatHistoryManager.swift:39)

**Problem:** When streaming starts:
1. A draft message with content "Generating..." is appended (line 321-325)
2. Streaming chunks update this message via `handleLocalModelStreamingChunk`
3. `ChatHistoryManager.append()` filters empty assistant messages via `ChatMessageVisibilityPolicy.isEmptyAssistantMessage`
4. The draft message may be filtered out if content becomes empty during updates

**Code:**
```swift
// ChatHistoryManager.append filters messages
public func append(_ message: ChatMessage) {
    if ChatMessageVisibilityPolicy.isEmptyAssistantMessage(message) {
        return  // Message is silently dropped!
    }
    messages.append(message)
    saveHistoryAsync()
}
```

### Issue 3: Message Update Race Conditions

**Location:** [`ConversationManager.swift:152-177`](compass/Services/ConversationManager.swift:152)

**Problem:** The streaming handler has potential race conditions:
1. `activeStreamingRunId` and `draftAssistantMessageId` are checked separately
2. The message lookup and update happen in separate steps
3. Multiple streaming events could interleave

**Code:**
```swift
private func handleLocalModelStreamingChunk(_ event: LocalModelStreamingChunkEvent) {
    guard let runId = activeStreamingRunId, runId == event.runId else { return }
    guard let draftId = draftAssistantMessageId else { return }
    
    draftAssistantText.append(event.chunk)  // Mutable state modification
    // ... then looks up and updates message
}
```

### Issue 4: Orchestration Flow Error Handling

**Location:** [`ConversationSendCoordinator.swift:49-88`](compass/Services/ConversationSendCoordinator.swift:49), [`FinalResponseHandler.swift:69-120`](compass/Services/ConversationFlow/FinalResponseHandler.swift:69)

**Problem:** The orchestration flow has issues:
1. `send()` method creates a draft message but doesn't handle all error paths
2. `FinalResponseHandler.appendFinalMessageAndLog` tries to update draft by ID but may fail silently
3. If orchestration fails mid-way, the draft "Generating..." message remains

**Code Flow:**
```
startSendTask → append draft "Generating..." 
  → sendCoordinator.send() 
  → orchestration graph runs
  → FinalResponseHandler.appendFinalMessageAndLog tries to update draft
  → If orchestration throws, draft remains with "Generating..."
```

### Issue 5: UI Refresh Mechanism

**Location:** [`AIChatPanel.swift:107-111`](compass/Components/AIChatPanel.swift:107), [`MessageListView.swift:28-42`](compass/Components/MessageListView.swift:28)

**Problem:** The UI uses workarounds to force refresh:
1. `refreshTick` counter is incremented to force view updates
2. `visibleMessagesSignature` creates a string hash to detect changes
3. These indicate the underlying observation isn't working correctly

**Code:**
```swift
// AIChatPanel.swift
.onReceive(conversationManager.statePublisher) { _ in
    Task { @MainActor in
        refreshTick &+= 1  // Force refresh workaround
    }
}

// MessageListView.swift
private var visibleMessagesSignature: String {
    visibleMessages.suffix(20).map { ... }.joined(separator: "~")
}
```

### Issue 6: Duplicate Message Storage References

**Location:** [`ConversationManager.swift`](compass/Services/ConversationManager.swift)

**Problem:** `ConversationManager` has two ways to access messages:
1. `historyCoordinator.messages` (used in most places)
2. `historyManager.messages` (used in `explainCode` and `refactorCode`)

This can lead to inconsistencies if they get out of sync.

## Recommended Fixes

### Fix 1: Simplify State Management

1. **Remove `ChatHistoryCoordinator`** - It's a pass-through that adds complexity
2. **Use `ChatHistoryManager` directly** in `ConversationManager`
3. **Remove manual observation setup** - Let SwiftUI's `@ObservedObject` handle it
4. **Remove `refreshTick` workaround** - Fix the underlying observation

### Fix 2: Fix Draft Message Handling

1. **Don't filter draft messages** - Add a flag to identify draft messages
2. **Handle empty content gracefully** during streaming
3. **Ensure draft is always updated** on completion/error

### Fix 3: Fix Streaming Race Conditions

1. **Use a single atomic state object** for streaming state
2. **Use `@MainActor` isolation** consistently
3. **Add proper cancellation handling**

### Fix 4: Improve Error Handling

1. **Always clean up draft message** on error
2. **Show error in chat** instead of leaving "Generating..."
3. **Add timeout handling** for stuck operations

### Fix 5: Fix UI Observation

1. **Use `@ObservedObject` properly** on `ConversationManager`
2. **Remove signature-based change detection**
3. **Use SwiftUI's built-in diffing**

## Implementation Order

1. **Phase 1: State Management Cleanup**
   - Remove `ChatHistoryCoordinator`
   - Simplify `ConversationManager` observation
   - Fix `AIChatPanel` refresh mechanism

2. **Phase 2: Draft Message Handling**
   - Add draft message identification
   - Fix visibility policy
   - Ensure proper cleanup on error

3. **Phase 3: Streaming Improvements**
   - Consolidate streaming state
   - Fix race conditions
   - Improve error handling

4. **Phase 4: Testing**
   - Test streaming with local models
   - Test error scenarios
   - Test UI responsiveness

## Architecture Diagram

```mermaid
graph TD
    subgraph Current - Complex
        A[ChatHistoryManager] -->|@Published messages| B[ChatHistoryCoordinator]
        B -->|pass-through| C[ConversationManager]
        C -->|manual observation| D[AIChatPanel]
        D -->|refreshTick workaround| E[UI Update]
    end
    
    subgraph Proposed - Simplified
        A2[ChatHistoryManager] -->|@Published messages| C2[ConversationManager]
        C2 -->|@ObservedObject| D2[AIChatPanel]
        D2 -->|automatic| E2[UI Update]
    end
```

## What is NOT Changing (Preserved)

1. **Orchestration Graph (Agentic Rail Chain)** - The entire flow graph remains intact:
   - `ConversationFlowGraphFactory.swift` - Graph construction
   - All orchestration nodes: `InitialResponseNode`, `StrategicPlanningNode`, `TacticalPlanningNode`, `ToolLoopNode`, `ReasoningCorrectionsNode`, `DeliveryGateNode`, `EmptyResponseRecoveryNode`, `FinalResponseNode`, `QAReviewNode`, etc.
   - The agentic flow logic and corrections

2. **Streaming Infrastructure** - Preserved and improved:
   - `LocalModelStreamingChunkEvent` event flow
   - `LocalModelProcessAIService` streaming in MLX
   - Event bus subscription pattern
   - Only the state handling in `ConversationManager` will be improved

3. **Tool Execution** - No changes:
   - `AIToolExecutor` and all tool implementations
   - Tool scheduling and concurrency
   - Progress reporting

4. **AI Service Layer** - No changes:
   - `OpenRouterAIService`
   - `LocalModelProcessAIService`
   - `AIInteractionCoordinator`

## Files to Modify

1. **Remove:**
   - `compass/Services/ChatHistoryCoordinator.swift` (pass-through wrapper)

2. **Modify:**
   - `compass/Services/ConversationManager.swift` - Use ChatHistoryManager directly, fix streaming state
   - `compass/Services/ChatHistoryManager.swift` - Add draft message support, improve upsert
   - `compass/Components/AIChatPanel.swift` - Remove refreshTick workaround, fix observation
   - `compass/Components/MessageListView.swift` - Simplify change detection
   - `compass/Models/ChatMessage.swift` - Add isDraft flag
   - `compass/Models/ChatMessageVisibilityPolicy.swift` - Handle draft messages properly
   - `compass/Services/ConversationSendCoordinator.swift` - Use ChatHistoryManager directly
   - `compass/Services/ConversationFlow/FinalResponseHandler.swift` - Update reference
   - `compass/Services/ConversationFlow/ToolLoopHandler.swift` - Update reference
   - `compass/Services/ConversationFlow/InitialResponseHandler.swift` - Update reference
   - `compass/Services/ConversationFlow/QAReviewHandler.swift` - Update reference
   - `compass/Services/ConversationFlow/ReasoningCorrectionsHandler.swift` - Update reference
   - `compass/Services/Orchestration/Nodes/*.swift` - Update coordinator references to manager

3. **Add:**
   - `compass/Services/StreamingState.swift` - Consolidated streaming state (optional, may just fix in place)
