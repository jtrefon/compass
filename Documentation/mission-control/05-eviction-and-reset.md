# 05 — Eviction & Controlled Reset

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Overview

This document specifies how context is evicted and how controlled resets work on both the local and cloud paths. The key principle: **eviction is note-aware** (the model's declared intent determines what's disposable) and **resets are controlled** (one intentional full-prefill, not death by a thousand truncations).

---

## 2. Local Path: Controlled Reset

### 2.1 Why Not Progressive Eviction?

The current `budgetMessages` approach truncates the system prompt progressively as messages grow. This:
1. Invalidates the entire KV cache every turn (system prompt is the prefix)
2. Sacrifices instructions for stale tool output
3. Still fills up — just slower

Controlled reset is better: let the context grow naturally during exploration (KV cache grows, no invalidation), then do ONE intentional full-prefill when context is 75% full. The fresh context is rebuilt from Mission Control + protected reads + recent results.

### 2.2 Reset Trigger

```swift
// In LocalModelToolLoop.execute(), after each iteration:

let budget = missionControlBuilder.computeBudget(
    messages: history.requestMessages,
    contextLength: configuration.contextLength,
    approximateTokenCount: { [self] in approximateTokenCount($0) }
)

if budget.percentUsed > 75 {
    try await performControlledReset(
        history: history,
        conversationId: configuration.conversationId,
        contextLength: configuration.contextLength,
        inferenceConfiguration: configuration.inferenceConfiguration
    )
}
```

**Threshold: 75%.** This leaves 25% of context for the model to work in after the reset. On a 30K context, the reset fires at ~22.5K used, leaving ~7.5K of fresh working space (plus the ~5-6K of Mission Control that's re-injected).

**Configurable:** The threshold can be overridden via `COMPASS_RESET_THRESHOLD` env var for experimentation.

### 2.3 Reset Procedure

```swift
@MainActor
private func performControlledReset(
    history: any ConversationHistoryProviding,
    conversationId: String,
    contextLength: Int,
    inferenceConfiguration: LocalModelInferenceConfiguration
) async throws {
    // 1. Get current working memory and plan
    let workingMemory = await workingMemoryStore.get(conversationId: conversationId)
    let plan = await ConversationPlanStore.shared.getPlan(conversationId: conversationId)
    
    // 2. Get edit_target tool results (protected — must carry through)
    let editTargetSections = workingMemory.editTargetSections()
    let editTargetMessages = history.requestMessages.filter { msg in
        guard msg.role == .tool, let toolCallId = msg.toolCallId else { return false }
        return ToolResultNoteTracker.shared.isEditTarget(toolCallId: toolCallId)
    }
    
    // 3. Get last 3-5 tool results (active working set)
    let recentToolMessages = history.requestMessages
        .filter { $0.role == .tool }
        .suffix(5)
    
    // 4. Get smart retrieval from FAISS (NPU-scored relevant evicted chunks)
    let taskContext = currentTaskContext(plan: plan, workingMemory: workingMemory)
    let retrievedChunks = await semanticCompressor.scoreForRetrieval(
        taskContext: taskContext,
        workingMemoryText: workingMemory.renderForContext(),
        candidateCount: 10
    )
    let topRetrieved = retrievedChunks.prefix(5)
    
    // 5. Build fresh context
    var freshMessages: [ChatMessage] = []
    
    // a. System messages (head) — preserved
    let systemMessages = history.requestMessages.filter { $0.role == .system }
    freshMessages.append(contentsOf: systemMessages)
    
    // b. Original user request — preserved (the task definition)
    if let firstUserMsg = history.requestMessages.first(where: { $0.role == .user && !$0.content.hasPrefix("## MISSION CONTROL") }) {
        freshMessages.append(firstUserMsg)
    }
    
    // c. Retrieved context from cold storage
    if !topRetrieved.isEmpty {
        let retrievedText = topRetrieved.enumerated().map { (i, chunk) in
            "[\(chunk.source)] \(chunk.text.prefix(200))"
        }.joined(separator: "\n")
        freshMessages.append(ChatMessage(
            role: .user,
            content: "## Retrieved Context (from previous exploration)\n\(retrievedText)"
        ))
    }
    
    // d. Edit target reads (protected)
    for msg in editTargetMessages {
        freshMessages.append(msg)
    }
    
    // e. Recent tool results (active working set)
    for msg in recentToolMessages {
        freshMessages.append(msg)
    }
    
    // f. Reset notice
    freshMessages.append(ChatMessage(
        role: .user,
        content: "## Context Reset\nContext was reset to free space. Your Mission Control (goal, plan, working memory, key excerpts) is preserved in the next message. Continue from your notes — do not re-explore files you already have notes on."
    ))
    
    // g. Mission Control (always last — what the model sees right before generating)
    let missionControl = await missionControlBuilder.build(
        conversationId: conversationId,
        contextLength: contextLength,
        usedTokens: 0  // fresh context — will be recomputed
    )
    freshMessages.append(ChatMessage(role: .user, content: missionControl))
    
    // 6. Replace history with fresh context
    // NOTE: This is the ONE place where history is NOT append-only.
    // This is intentional and controlled — the KV cache is flushed,
    // and the fresh context is prefilled from scratch.
    await history.replaceWithReset(freshMessages)
    
    // 7. Mark reset in working memory
    await workingMemoryStore.markReset(conversationId: conversationId)
    
    // 8. Clear key excerpts (they'll be rebuilt from new tool results)
    await semanticCompressor.clearKeyExcerpts(conversationId: conversationId)
    
    // 9. Log the reset for telemetry
    await AIToolTraceLogger.shared.log(type: "mission_control.reset", data: [
        "conversationId": conversationId,
        "previousMessageCount": history.requestMessages.count,
        "freshMessageCount": freshMessages.count,
        "editTargetsPreserved": editTargetMessages.count,
        "retrievedChunks": topRetrieved.count,
        "workingMemoryNotes": workingMemory.notes.count
    ])
}
```

### 2.4 ChatHistoryCoordinator Extension

The `replaceWithReset` method is the ONE non-append-only operation on `ChatHistoryCoordinator`. It's clearly marked as reset-only:

```swift
extension ChatHistoryCoordinator {
    /// Replace the entire committed history with a fresh set.
    /// This is the ONLY non-append-only operation — used exclusively
    /// by controlled context resets. The KV cache is intentionally
    /// flushed; the fresh context is prefilled from scratch.
    func replaceWithReset(_ messages: [ChatMessage]) async {
        _committed = messages
        draft = nil
        liveToolStatus = [:]
        liveToolMessages = [:]
        recompose()
    }
}
```

### 2.5 What's Preserved vs What's Evicted

| Content | Preserved through reset? | Why |
|---|---|---|
| System messages | YES (head) | Instructions are sacred |
| Original user request | YES | The task definition must survive |
| Mission Control (goal, plan, notes, excerpts, budget) | YES (rebuilt fresh) | The agent's persistent state |
| edit_target tool results | YES | Model needs exact code to edit |
| Last 3-5 tool results | YES | Active working set |
| Top-5 NPU-retrieved chunks | YES | Most relevant evicted content |
| Old finding-tagged tool results | NO (evicted to FAISS) | Knowledge preserved in notes |
| Old non-noted tool results | NO (evicted to FAISS) | Model chose not to note — low value |
| Old assistant responses | NO (evicted) | Reasoning is captured in notes |
| Old Mission Control messages | NO (evicted) | Replaced by fresh Mission Control |

### 2.6 KV Cache Impact

```
Before reset:
  [system: 8K] [msgs: 20K] [MC: 3K] = 31K total
  KV cache: 28K cached (system + msgs), 3K new (MC)

After reset:
  [system: 8K] [user_request: 0.5K] [retrieved: 1K] [edit_targets: 2K]
  [recent: 3K] [reset_notice: 0.2K] [MC: 5K] = 19.7K total
  
  KV cache: FLUSHED (intentional)
  Full prefill: 19.7K tokens (~2-3 seconds on Qwen3.5-4B)
  
  Free context: 30K - 19.7K = 10.3K for the model to work in

Next turn (after reset):
  [system: 8K] [msgs: 2K] [MC: 5.2K] = 15.2K total
  KV cache: 10K cached (system + msgs), 5.2K new (MC)
  No invalidation — system prompt unchanged, msgs append-only
```

**One prefill per reset cycle.** Compare to current: one prefill per turn after budget exceeded.

---

## 3. Cloud Path: Note-Aware Front Eviction

### 3.1 No Reset Needed

The cloud path (OpenRouter) is stateless — every request rebuilds from scratch. No KV cache. No reset needed. Instead, `PipelineProcessor.prepareForRequest()` is enhanced with note-aware eviction:

### 3.2 Enhanced PipelineProcessor

```swift
extension PipelineProcessor {
    
    /// Note-aware version of prepareForRequest.
    /// Evicts tool results based on note intent:
    ///   - finding-tagged results: evicted first (knowledge in notes)
    ///   - non-noted results: evicted second (model chose not to note)
    ///   - edit_target results: preserved (needed for editing)
    ///   - recent results: preserved (active working set)
    static func prepareForRequestNoteAware(
        messages: [ChatMessage],
        modelID: String?,
        conversationId: String,
        noteTracker: ToolResultNoteTracker,
        preservesCache: Bool,
        runId: String?,
        stage: AIRequestStage?
    ) -> [ChatMessage] {
        guard !preservesCache else { return messages }
        
        let budgetTokens = requestTokenBudget(modelID: modelID)
        let budgetChars = max(1, budgetTokens * 4)
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > budgetChars else { return messages }
        
        // 1. Keep system messages (head)
        var head: [ChatMessage] = []
        var cursor = 0
        while cursor < messages.count, messages[cursor].role == .system {
            head.append(messages[cursor])
            cursor += 1
        }
        
        // 2. Categorize remaining messages by evictability
        var editTargetResults: [ChatMessage] = []
        var findingResults: [ChatMessage] = []
        var nonNotedResults: [ChatMessage] = []
        var otherMessages: [ChatMessage] = []
        var recentToolResults: [ChatMessage] = []
        
        let toolMessages = messages[cursor...].filter { $0.role == .tool }
        let recentToolCallIds = Set(toolMessages.suffix(5).compactMap { $0.toolCallId })
        
        for msg in messages[cursor...] {
            if msg.role == .tool, let toolCallId = msg.toolCallId {
                if recentToolCallIds.contains(toolCallId) {
                    recentToolResults.append(msg)
                } else if noteTracker.isEditTarget(toolCallId: toolCallId) {
                    editTargetResults.append(msg)
                } else if noteTracker.isFinding(toolCallId: toolCallId) {
                    findingResults.append(msg)
                } else {
                    nonNotedResults.append(msg)
                }
            } else if msg.content.hasPrefix("## MISSION CONTROL") {
                // Skip old Mission Control messages — they're rebuilt each turn
                continue
            } else {
                otherMessages.append(msg)
            }
        }
        
        // 3. Assemble within budget (priority order)
        var result: [ChatMessage] = head
        var used = head.reduce(0) { $0 + $1.content.count }
        
        // Priority 1: Other messages (user, assistant) — keep most recent
        for msg in otherMessages.reversed() {
            if used + msg.content.count <= budgetChars {
                result.insert(msg, at: head.count)
                used += msg.content.count
            }
        }
        
        // Priority 2: Recent tool results (active working set)
        for msg in recentToolResults {
            if used + msg.content.count <= budgetChars {
                result.append(msg)
                used += msg.content.count
            }
        }
        
        // Priority 3: Edit target results (protected)
        for msg in editTargetResults {
            if used + msg.content.count <= budgetChars {
                result.append(msg)
                used += msg.content.count
            }
        }
        
        // Priority 4: Non-noted results (model didn't note — lower value)
        for msg in nonNotedResults.reversed() {
            if used + msg.content.count <= budgetChars {
                result.append(msg)
                used += msg.content.count
            }
        }
        
        // Priority 5: Finding results (knowledge in notes — lowest priority)
        for msg in findingResults.reversed() {
            if used + msg.content.count <= budgetChars {
                result.append(msg)
                used += msg.content.count
            }
        }
        
        // Pair-safe guard: never start with orphaned tool result
        while result.count > 1, result.first?.role == .tool {
            result.removeFirst()
        }
        
        let dropped = messages.count - result.count
        if dropped > 0 {
            Task {
                await AppLogger.shared.info(
                    category: .ai,
                    message: "context.note_aware_truncated",
                    context: AppLogger.LogCallContext(metadata: [
                        "droppedMessages": dropped,
                        "findingEvicted": findingResults.count,
                        "nonNotedEvicted": nonNotedResults.count,
                        "editTargetsPreserved": editTargetResults.count,
                        "budgetTokens": budgetTokens
                    ])
                )
            }
        }
        
        return result
    }
}
```

### 3.3 Eviction Priority (Cloud)

```
1. Old Mission Control messages          → DROPPED (rebuilt each turn)
2. Finding-tagged tool results (oldest)  → DROPPED (knowledge in notes)
3. Non-noted tool results (oldest)       → DROPPED (model didn't note)
4. Old user/assistant messages           → DROPPED if needed
5. Edit_target tool results              → PRESERVED (needed for editing)
6. Recent tool results (last 5)          → PRESERVED (active working set)
7. System messages                       → PRESERVED (head, never dropped)
```

---

## 4. Token Budget Calculation

### 4.1 Local Path

```swift
func computeBudget(
    messages: [ChatMessage],
    contextLength: Int,
    approximateTokenCount: (String) -> Int
) -> BudgetInfo {
    var usedTokens = 0
    for message in messages {
        let content = message.role == .tool
            ? replayToolMessageContent(from: message)
            : message.content
        usedTokens += approximateTokenCount(content) + 16  // 16 = per-message overhead
    }
    return BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)
}
```

The `approximateTokenCount` function is the existing one from `LocalModelProcessAIService` — either the exact tokenizer or the `(count + 3) / 4` approximation.

### 4.2 Cloud Path

```swift
func computeBudget(
    messages: [ChatMessage],
    modelID: String?
) -> BudgetInfo {
    let contextLength = PipelineProcessor.requestTokenBudget(modelID: modelID)
    let usedTokens = messages.reduce(0) { $0 + ($1.content.count / 4) }  // ~4 chars/token
    return BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)
}
```

### 4.3 Dynamic Context Length

| Source | How context length is determined |
|---|---|
| Local (MLX) | `inferenceConfiguration.contextLength` — from settings slider (30K to 262K) |
| Cloud (OpenRouter) | `ModelContextRegistry.shared.contextLength(for: modelID)` — from model catalog |
| Fallback | `PipelineProcessor.defaultContextWindowTokens` (262K) |

No hardcoded numbers. The system adapts to whatever the user has configured.

---

## 5. preservesCache Fix

### 5.1 Current Bug

`LocalModelToolLoop` constructs `SendMessageWithRetryRequest` without passing `preservesCache: true`:

```swift
// Current (buggy):
let response = try await aiInteractionCoordinator.sendMessageWithRetry(
    .init(messages: history.requestMessages, tools: tools,
          mode: configuration.mode, projectRoot: configuration.projectRoot,
          runId: configuration.runId, stage: stage,
          conversationId: configuration.conversationId, usesLocalModel: true)
    // ← preservesCache defaults to false
).get()
```

This means `PipelineProcessor.prepareForRequest()` truncates messages on every tool-loop iteration, even though the first send (from `ConversationManager`) passes `preservesCache: true`.

### 5.2 Fix

With Mission Control, the `preservesCache` flag becomes less critical because:
1. The system prompt is never truncated (Mission Control is in the last user message, not the system prompt)
2. Controlled reset handles context pressure intentionally

However, for consistency, the fix is still applied:

```swift
// Fixed:
let response = try await aiInteractionCoordinator.sendMessageWithRetry(
    .init(messages: history.requestMessages, tools: tools,
          mode: configuration.mode, projectRoot: configuration.projectRoot,
          runId: configuration.runId, stage: stage,
          conversationId: configuration.conversationId, usesLocalModel: true,
          preservesCache: true)  // ← matches first-send behavior
).get()
```

And in `finalResponse`:

```swift
private func finalResponse(configuration: Configuration, tools: [AITool]) async throws -> AIServiceResponse {
    try await aiInteractionCoordinator.sendMessageWithRetry(
        .init(messages: history.requestMessages, tools: tools,
              mode: configuration.mode, projectRoot: configuration.projectRoot,
              runId: configuration.runId, stage: .tool_loop,
              conversationId: configuration.conversationId, usesLocalModel: true,
              preservesCache: true)  // ← fixed
    ).get()
}
```

### 5.3 budgetMessages Replacement

The current `budgetMessages` function in `LocalModelPromptBuilder` is replaced. Instead of truncating the system prompt, the system:

1. Lets messages grow naturally (append-only, KV cached)
2. Appends Mission Control as the last user message (no system prompt modification)
3. Triggers controlled reset at 75% (one intentional prefill)

The `budgetMessages` function is either deleted or repurposed to only compute the token budget (no truncation):

```swift
// New role: compute budget only, no truncation
func computeBudget(
    _ messages: [ChatMessage],
    explicitContext: String?,
    systemContent: String,
    inferenceConfiguration: LocalModelInferenceConfiguration,
    approximateTokenCount: (String) -> Int
) -> (messageTokens: Int, systemTokens: Int, totalTokens: Int, percentUsed: Int) {
    let reservedOutputTokens = inferenceConfiguration.maxOutputTokens
    let overheadTokens = 256
    let availableBudget = max(256, inferenceConfiguration.contextLength - reservedOutputTokens - overheadTokens)
    
    var messageTokens = 0
    for message in messages {
        let content = message.role == .tool ? replayToolMessageContent(from: message) : message.content
        messageTokens += approximateTokenCount(content) + 16
    }
    
    let systemTokens = approximateTokenCount(systemContent) + approximateTokenCount(explicitContext ?? "")
    let totalTokens = messageTokens + systemTokens
    let percentUsed = (totalTokens * 100) / max(1, availableBudget)
    
    return (messageTokens, systemTokens, totalTokens, percentUsed)
    // NOTE: No truncation. The caller checks percentUsed and triggers reset if > 75%.
}
```

---

## 6. Reset Telemetry

Every controlled reset is logged for observability:

```json
{
  "type": "mission_control.reset",
  "conversationId": "ABC-123",
  "previousMessageCount": 47,
  "freshMessageCount": 12,
  "editTargetsPreserved": 2,
  "retrievedChunks": 5,
  "workingMemoryNotes": 8,
  "previousTokenEstimate": 22500,
  "freshTokenEstimate": 8500,
  "tokensSaved": 14000,
  "contextLength": 30000,
  "thresholdPercent": 75
}
```

This lets us measure:
- How many resets per task (frequency)
- How much context is saved per reset (efficiency)
- Whether the model continues effectively after reset (quality)

---

## 7. Edge Cases

### 7.1 Reset during edit_target

If a reset fires while the model has an `edit_target` read but hasn't edited yet, the read is preserved (carried through the reset). The model can continue to the edit without re-reading.

### 7.2 Reset with no notes

If the model hasn't taken any notes, the reset still fires but Mission Control's working memory section is empty. The model gets the reset notice + budget guidance + plan, but no notes. This is a degradation signal — the prompt should have encouraged noting. The model will likely re-explore, but with the budget awareness, it should note this time.

### 7.3 Reset with no plan

If no plan exists, Mission Control shows "No plan set." The reset still fires. The model is prompted to create a plan via the goal section.

### 7.4 Multiple resets in one task

If the task is large enough to require multiple resets, each reset rebuilds from the latest working memory + plan. Notes accumulate across resets (they're persisted). Each reset is independent — the model doesn't need to know how many resets have happened.

### 7.5 Reset during streaming

The reset check happens at the top of the loop iteration, before the model starts generating. It never interrupts a streaming response.

### 7.6 Cloud path with no FAISS

If FAISS is not available (`COMPASS_ENABLE_RAG` not set), the smart retrieval during reset falls back to "last 5 tool results" (naive heuristic). The rest of the reset procedure works normally.
