# Fix Plan: LangGraph Orchestration Failures

## Executive Summary

The TypeScript refactoring failure was caused by **broken plan supervision** in the LangGraph orchestration. The system creates plans correctly but fails to enforce them, allowing premature final responses and incorrectly marking incomplete work as done.

---

## Root Cause Analysis

### Issue 1: Premature Final Response Delivery (Critical)

**Location:** `ConditionalToolLoopNode.swift` + ToolLoopHandler logic

**Problem:** The system delivers `final_response` when the model stops making tool calls, regardless of whether the planned work is complete.

**Evidence from telemetry:**
- At 15:19:53: Model delivered final_response after only listing files (no TS files created)
- At 15:26:29: Model delivered final_response after only creating tsconfig.json
- At 15:29:55: Model delivered final_response without deleting all .js files

**Code reference:** 
- `ConditionalToolLoopNode.swift` lines 33-38: Always proceeds to `nextNodeId` regardless of plan completion
- `ToolLoopHandler.swift` lines 418-430: `shouldForceContinuationForIncompletePlan` only triggers when `toolCalls?.isEmpty`

### Issue 2: False Plan Completion Marking (Critical)

**Location:** `FinalResponseHandler.swift` lines 226-243

**Problem:** The function `completeRemainingPlanItems` marks ALL pending plan items as completed when delivering final_response, WITHOUT verifying actual work completion.

```swift
// CURRENT BUGGY CODE (lines 226-243)
private func completeRemainingPlanItems(conversationId: String) async {
    guard let plan = await ConversationPlanStore.shared.get(conversationId: conversationId),
          !plan.isEmpty,
          let completedPlan = PlanChecklistTracker.markAllPendingItemsCompleted(in: plan) else {
        return  // Early return if no plan - GOOD
    }
    // BUG: Marks ALL items as completed without checking if they were actually done!
    await ConversationPlanStore.shared.set(conversationId: conversationId, plan: completedPlan)
}
```

**Impact:** Even if 0% of the plan is complete, final_response marks it as 100% complete.

### Issue 3: Plan Progress Not Enforced Before Final Response

**Location:** Graph flow in `ConversationFlowGraphFactory.swift`

**Problem:** The flow is:
```
ToolLoop → ConditionalToolLoop → DeliveryGate → FinalResponse
```

There is no node that checks "Is plan complete?" before allowing FinalResponse. The `ConditionalToolLoopNode` only checks if model has tool calls, not if plan is done.

---

## Proposed Fixes

### Fix 1: Add Plan Completion Check Before Final Response

**File:** `compass/Services/Orchestration/Nodes/ConditionalToolLoopNode.swift`

**Change:** Before proceeding to FinalResponseNode, verify plan completion:

```swift
// In run(state:) function, before returning:
let planProgress = PlanChecklistTracker.progress(
    in: await ConversationPlanStore.shared.get(conversationId: state.request.conversationId) ?? ""
)

if planProgress.total > 0 && !planProgress.isComplete {
    // Force continuation - don't allow final_response yet
    let forcedContinuation = try await handler.handleToolLoopIfNeeded(...)
    return OrchestrationState(..., transition: .next(toolLoopNodeId))  // Loop back, don't proceed to final
}
```

### Fix 2: Remove False Plan Completion in FinalResponseHandler

**File:** `compass/Services/ConversationFlow/FinalResponseHandler.swift`

**Change:** Replace `completeRemainingPlanItems` with a verification approach:

```swift
private func handlePlanOnCompletion(conversationId: String) async {
    guard let plan = await ConversationPlanStore.shared.get(conversationId: conversationId),
          !plan.isEmpty else {
        return
    }
    
    let progress = PlanChecklistTracker.progress(in: plan)
    
    // Only mark items as done if they're actually complete, don't force-complete remaining items
    if progress.isComplete {
        // Plan is truly complete - this is fine
        return
    } else {
        // Plan NOT complete - log warning, DO NOT mark items as done
        await logIncompletePlanWarning(conversationId: conversationId, progress: progress)
        // Don't call markAllPendingItemsCompleted!
    }
}
```

### Fix 3: Add Plan-Aware Delivery Gate

**File:** `compass/Services/Orchestration/Nodes/DeliveryGateNode.swift`

**Change:** Enhance DeliveryGate to check plan completion:

```swift
// Before allowing final response, verify plan:
let plan = await ConversationPlanStore.shared.get(conversationId: request.conversationId) ?? ""
let progress = PlanChecklistTracker.progress(in: plan)

if progress.total > 0 && !progress.isComplete {
    // Add nudge to model about incomplete plan
    // Don't allow final_response until plan is complete
}
```

### Fix 4: Improve Force Continuation Logic

**File:** `compass/Services/ConversationFlow/ToolLoopHandler.swift`

**Change:** The `shouldForceContinuationForIncompletePlan` should also trigger when:
- Model attempts final_response with incomplete plan
- Even if model has tool calls but they're not making progress on the plan

```swift
// Expand conditions at line 418:
if mode == .agent,
   currentResponse.toolCalls?.isEmpty ?? true,  // Keep this
   await shouldForceContinuationForIncompletePlan(...) { // Keep this
    // ADD: Also trigger if plan is incomplete AND model tried to deliver final
}
```

---

## Implementation Priority

| Priority | Fix | Complexity | Impact |
|----------|-----|------------|--------|
| P0 | Fix 2: Remove false plan completion | Low | Critical - prevents false success |
| P0 | Fix 1: Add plan check before final | Medium | Critical - enforces completion |
| P1 | Fix 3: Plan-aware delivery gate | Medium | High - comprehensive protection |
| P2 | Fix 4: Improve force continuation | Medium | Medium - edge case handling |

---

## Files to Modify

1. `compass/Services/ConversationFlow/FinalResponseHandler.swift` - Fix plan completion logic
2. `compass/Services/Orchestration/Nodes/ConditionalToolLoopNode.swift` - Add plan check
3. `compass/Services/Orchestration/Nodes/DeliveryGateNode.swift` - Enhance with plan verification
4. `compass/Services/ConversationFlow/ToolLoopHandler.swift` - Improve force continuation

---

## Testing Checklist

After fixes, verify:
- [ ] TypeScript refactoring completes ALL file deletions
- [ ] Plan shows accurate completion percentage
- [ ] Final response only delivered when plan is 100% complete
- [ ] Incomplete plans trigger force continuation
- [ ] No false "plan complete" marks in telemetry
