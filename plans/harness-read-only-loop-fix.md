# Harness Test Suite: Read-Only Tool Loop Diagnosis and Fix Plan

## Problem Statement

The agent gets stuck in a read-only tool loop during complex refactoring tasks:
- Model repeatedly calls `index_list_memories`, `index_find_files`, `read_file` etc.
- Model never transitions to execution tools (`write_file`, `replace_in_file`, `run_command`)
- Generation takes 1.5+ minutes between tool calls
- After ~7 minutes, the harness fails with MLX memory error

## Evidence from app.ndjson

```
10:21:40 - index_list_memories (success)
10:21:40 - index_find_files (success)
10:23:05 - index_list_memories (success)  # 1.5 min later, same tool
10:24:49 - index_find_files x3 (success)  # 1.5 min later, read-only
10:26:10 - index_list_memories (success)  # 1.5 min later, still read-only
```

Pattern: Model is exploring but never executing.

## Root Cause Analysis

### 1. Read-Only Loop Detection Works

In [`ToolLoopHandler.swift:669-700`](compass/Services/ConversationFlow/ToolLoopHandler.swift:669):

```swift
private func shouldStopForReadOnlyToolLoopStall(
    toolCalls: [AIToolCall],
    consecutiveReadOnlyToolIterations: inout Int,
    ...
) -> Bool {
    let isReadOnlyBatch = toolCalls.allSatisfy { readOnlyLoopToolNames.contains($0.name) }
    consecutiveReadOnlyToolIterations += 1
    return consecutiveReadOnlyToolIterations >= 3 || repeatedReadOnlyToolBatchCount >= 2
}
```

The detection correctly identifies read-only loops.

### 2. Recovery Strategy is Wrong

In [`ToolLoopHandler.swift:794-832`](compass/Services/ConversationFlow/ToolLoopHandler.swift:794):

```swift
private func requestFinalResponseForStalledToolLoop(...) async throws -> AIServiceResponse {
    let correctionSystem = ChatMessage(
        role: .system,
        content: "You kept calling tools without producing a user-visible response. " +
            "Stop calling tools now and provide a final response in plain text."
    )
    // ...
    let followup = try await aiInteractionCoordinator
        .sendMessageWithRetry(...,
            tools: [],  // <-- NO TOOLS!
            ...
        )
}
```

**Problem**: When read-only loop is detected:
1. Tools are removed (`tools: []`)
2. Model is told to "stop calling tools"
3. Model gives up instead of transitioning to execution

### 3. Missing Transition Prompt

There's no prompt that says:
> "You've gathered enough context. Now EXECUTE the changes using write_file or replace_in_file."

## Fix Plan

### Phase 1: Fix Recovery Strategy

Modify `requestFinalResponseForStalledToolLoop` to force execution transition:

```swift
private func requestFinalResponseForStalledToolLoop(...) async throws -> AIServiceResponse {
    // NEW: Force execution transition instead of giving up
    let executionTools = availableTools.filter { !readOnlyLoopToolNames.contains($0.name) }
    
    let correctionSystem = ChatMessage(
        role: .system,
        content: """
        You have been gathering context with read-only tools but haven't made any changes yet.
        The user's request requires EXECUTION, not just exploration.
        
        You MUST now transition to execution:
        1. Use write_file to create new files
        2. Use replace_in_file to modify existing files
        3. Use run_command for build/test commands
        
        Do NOT call more read-only tools. Proceed with execution now.
        """
    )
    
    let followup = try await aiInteractionCoordinator
        .sendMessageWithRetry(...,
            tools: executionTools,  // <-- ONLY execution tools
            ...
        )
}
```

### Phase 2: Add Harness Telemetry

Create a diagnostic harness test that captures:

1. **Tool call timeline** - timestamp, tool name, arguments
2. **Read-only vs execution classification** - is this a read or write tool?
3. **Loop detection events** - when does `shouldStopForReadOnlyToolLoopStall` trigger?
4. **Recovery outcome** - what happens after stall detection?

```swift
func testHarnessReadOnlyLoopDetection() async throws {
    // ... setup ...
    
    var toolTimeline: [(Date, String, Bool)] = []  // (timestamp, toolName, isReadOnly)
    
    // Hook into tool execution to capture timeline
    // ...
    
    // Assert: After 3 read-only iterations, recovery should force execution
    // Assert: At least one execution tool should be called after recovery
}
```

### Phase 3: Improve Model Prompting

The model may not understand it should transition. Add explicit transition hints:

1. **In tool results**: Add hint after N read-only calls
   ```
   "You've gathered context. Consider proceeding to execution."
   ```

2. **In system prompt**: Add phase awareness
   ```
   "After gathering context, transition to execution. Don't over-explore."
   ```

3. **In tool loop step update**: Make transition explicit
   ```swift
   private func toolLoopStepUpdateInstructionMessage() -> ChatMessage {
       ChatMessage(
           role: .system,
           content: """
           Before returning tool calls, include a short update.
           
           IMPORTANT: If you've called 2+ read-only tools in a row, 
           you MUST transition to execution tools (write_file, replace_in_file).
           Do not keep exploring indefinitely.
           """
       )
   }
   ```

### Phase 4: Add Execution Tool Nudging

After consecutive read-only tools, inject a nudge:

```swift
// In handleToolLoopIfNeeded, after tool execution:
if consecutiveReadOnlyToolIterations >= 2 {
    let nudge = ChatMessage(
        role: .system,
        content: "Context gathering complete. Now proceed with execution using write_file or replace_in_file."
    )
    followupMessages.append(nudge)
}
```

## Test Coverage Plan

| Test | Purpose | Status |
|------|---------|--------|
| `testHarnessReadOnlyLoopDetection` | Verify detection triggers at 3 iterations | TODO |
| `testHarnessReadOnlyLoopRecovery` | Verify recovery forces execution | TODO |
| `testHarnessExecutionTransitionNudge` | Verify nudge appears after 2 read-only calls | TODO |
| `testProductionParityReactTodoThenSSRFollowup` | Full scenario with fixes | EXISTS |

## Phase 5: Telemetry - Tool Miss and Repeat Counters

### Tool Miss Counter

Track when model generates content that wasn't recognized/mapped to any tool:

```swift
struct ToolMissTelemetry {
    var totalResponses: Int = 0
    var responsesWithToolCalls: Int = 0
    var responsesWithoutToolCalls: Int = 0
    var textualToolCallPatterns: Int = 0  // Model wrote "tool_calls:" in text
    
    var missRate: Double {
        guard totalResponses > 0 else { return 0 }
        return Double(responsesWithoutToolCalls) / Double(totalResponses)
    }
}
```

**Production target**: 0 textual tool call patterns (model should use native tool calling)

### Repeat Counter

Track when requests get repeated (same tool call signature, same content):

```swift
struct RepeatTelemetry {
    var totalToolCalls: Int = 0
    var deduplicatedToolCalls: Int = 0  // Same signature removed
    var repeatedBatches: Int = 0  // Same batch signature
    var repeatedContent: Int = 0  // Same assistant content without tools
    
    var repeatRate: Double {
        guard totalToolCalls > 0 else { return 0 }
        return Double(deduplicatedToolCalls + repeatedBatches) / Double(totalToolCalls)
    }
}
```

**Production target**: 0 repeats (every tool call should be unique and productive)

### Integration Points

1. **In `ToolLoopHandler`**: Log telemetry after each iteration
2. **In `AgenticHarnessTests`**: Assert counters are 0 at test end
3. **In `ConversationLogStore`**: Persist for post-run analysis

### Telemetry Log Format

```json
{
  "type": "telemetry.tool_miss",
  "conversationId": "...",
  "data": {
    "totalResponses": 5,
    "responsesWithToolCalls": 4,
    "responsesWithoutToolCalls": 1,
    "textualToolCallPatterns": 0,
    "missRate": 0.2
  }
}
```

```json
{
  "type": "telemetry.repeat",
  "conversationId": "...",
  "data": {
    "totalToolCalls": 12,
    "deduplicatedToolCalls": 0,
    "repeatedBatches": 0,
    "repeatedContent": 0,
    "repeatRate": 0.0
  }
}
```

## Implementation Order

1. **Fix recovery strategy** - Most impactful, changes behavior immediately
2. **Add nudge after 2 read-only calls** - Prevents stall before detection
3. **Improve step update instruction** - Guides model behavior
4. **Add tool miss telemetry** - Track unrecognized tool patterns
5. **Add repeat counter telemetry** - Track repeated requests
6. **Add harness telemetry tests** - Verifies fixes work

## Success Criteria

1. Model transitions from read-only to execution within 5 tool calls
2. No more than 3 consecutive read-only tool iterations
3. **Tool miss counter = 0** (no textual tool call patterns)
4. **Repeat counter = 0** (no repeated tool calls or content)
5. `testProductionParityReactTodoThenSSRFollowup` passes without MLX memory error
6. Real-world SSR refactor scenario completes successfully