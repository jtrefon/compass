# Comprehensive Architecture: Agentic Loop Reliability

## Executive Summary

The agentic loop has a single root cause for all observed issues: **three competing systems independently decide "is the model done?"** — the `ToolLoopHandler` stall detectors, the `BranchReviewNode` signal analysis, and the `FinalResponseNode` content heuristics. They disagree, producing intermittent dropouts, dead loops, and 60s stalls.

**The fix:** Replace all three with a single structured signal: the `ReviewDecision` produced by the model itself. The model says "I'm done" — the framework believes it.

---

## Architecture Overview

```
                   ┌──────────────────────────────────────┐
                   │            OrchestrationGraphRunner    │
                   │         (unchanged — drives any graph) │
                   └──────────────────────────────────────┘
                                    │
┌──────────────────────────────────┼──────────────────────────────────┐
│                                  │                                  │
▼                                  ▼                                  ▼
┌──────────────┐      ┌──────────────────┐      ┌──────────────────┐
│ Dispatcher   │      │   ExecutorNode   │      │   ReviewerNode   │
│ (get initial │      │  (ToolLoopNode)  │      │  (new — wraps    │
│  response)   │ ──►  │   pure execution │ ──►  │   ReviewStrategy)│
└──────────────┘      │   NO stall checks│      │   produces       │
                      └──────────────────┘      │   ReviewDecision │
                                                └────────┬─────────┘
                                                         │
                                    ┌────────────────────┼────────────────────┐
                                    │                    │                    │
                                    ▼                    ▼                    ▼
                            ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐
                            │  .complete   │   │  .continue   │   │   .replan       │
                            │  → FinalNode │   │  → Executor  │   │   → Executor    │
                            └──────────────┘   └──────────────┘   └──────────────────┘
```

### Key principle

**Trust the model.** When the model produces a response with no tool calls, it chose to stop. Every other agentic system (Cursor, Claude Code, Anthropic, LangGraph) treats this as "I'm done." Our system should too.

---

## Components

### 1. ReviewDecision — structured completion signal (EXISTING)

```swift
enum ReviewDecision: Sendable, Codable {
    case complete(summary: String)
    case `continue`(updatedPlan: TaskPlan?)
    case replan(feedback: String)
    case blocked(reason: String, suggestedAction: String?)
}
```

**Status:** ✅ Built, unit tested (5 tests), Codable round-trip verified.

### 2. ReviewStrategy — pluggable evaluation (EXISTING)

```swift
protocol ReviewStrategy: Sendable {
    func evaluate(context: AgentContext) async throws -> ReviewDecision
}
```

**Status:** ✅ Built. One concrete implementation exists:
- `PlanCompletenessStrategy` — deterministic check of plan steps vs execution results (4 unit tests)

### 3. ExecutorNode — pure execution (EXISTING + MODIFIED)

```swift
protocol ExecutorNode: Sendable {
    func execute(plan: TaskPlan?, availableTools: [String], conversationId: String) async throws -> ExecutionResult
}
```

**Current:** `ToolLoopHandler.handleToolLoopIfNeeded()` is 3293 lines with 11 heuristic stall detectors mixed into the execution logic.

**Target:** The handler executes tools only. No stall detection, no completion heuristics, no post-loop recovery. When the model returns no tool calls, the handler returns immediately.

**What changes:**
- The `modelChoseToStop` flag gates all post-loop recovery (already implemented, verified working)
- The `ToolLoopNode` routes directly to `FinalResponseNode` when `modelChoseToStop` is true (already implemented)
- The `FinalResponseNode` skips re-prompt when routed directly from a `modelChoseToStop` decision (already implemented)

### 4. ReviewerNode — evaluation + routing (NEW — needs wiring)

```swift
protocol ReviewerNode: Sendable {
    func evaluate(plan: TaskPlan?, result: ExecutionResult, strategy: ReviewStrategy) async throws -> ReviewDecision
}
```

**What it does:** After the executor finishes a batch, the reviewer evaluates the results and produces a `ReviewDecision`. This replaces:
- The heuristic stall detectors in `ToolLoopHandler` (11 detectors — removed)
- The signal-based routing in `BranchReviewNode` (removed or simplified)
- The content heuristics in `FinalResponseHandler.requestFinalResponseIfNeeded` (removed or bypassed)

**Graph integration:** Currently `OrchestrationReviewerNode` exists and compiles but is not wired into the graph. It needs to be inserted between `ToolLoopNode` and `BranchReviewNode`.

### 5. Graph Topology (CURRENT)

```
dispatcher → tool_loop → empty_response_recovery → branch_review → final_response
```

### 6. Graph Topology (TARGET)

```
dispatcher → tool_loop → reviewer → branch_review → final_response
                              ↑          │
                              └─ continue ┘
```

When `modelChoseToStop` is true (the normal case), `ToolLoopNode` routes directly to `reviewer`, which produces `.complete` → routes directly to `final_response`. The `branch_review` and `empty_response_recovery` nodes are only reached when the tool loop terminated abnormally (stall, max iterations) — which should never happen in normal operation.

---

## Implementation Plan (4 phases)

### Phase 1: Model Completion Signal (IN PROGRESS — 80% complete)

**What:** Wire `modelChoseToStop` through the tool loop, graph routing, and finalization to eliminate the 60s stall.

| Step | Status | File |
|---|---|---|
| Add `modelChoseToStop` flag to `ToolLoopHandler` | ✅ Done | `ToolLoopHandler.swift` |
| Gate post-loop recovery on `!modelChoseToStop` | ✅ Done | `ToolLoopHandler.swift` |
| Add `modelChoseToStop` to `OrchestrationState` | ✅ Done | `OrchestrationState.swift` |
| Add `finalNodeId` to `ToolLoopNode` | ✅ Done | `ToolLoopNode.swift` |
| Route directly to final when model chose to stop | ✅ Done | `ToolLoopNode.swift` |
| Propagate flag through `updating()` | ✅ Done | `OrchestrationState.swift` |
| Skip re-prompt in `FinalResponseNode` when flag set | ✅ Done | `FinalResponseNode.swift` |
| Wire `finalNodeId` in `ConversationFlowGraphFactory` | ✅ Done | `ConversationFlowGraphFactory.swift` |
| **Test: verify 60s stall eliminated** | ❌ **TODO** | Run harness |

**Remaining work in Phase 1:** Run the harness with a CLEAN derived data and verify the 60s stall is eliminated. The code is all in place, but intermittent build caching may affect results.

### Phase 2: Wire ReviewerNode into Graph

**What:** Insert `OrchestrationReviewerNode` between `ToolLoopNode` and `BranchReviewNode`. When the tool loop finishes, the reviewer evaluates via `PlanCompletenessStrategy`. If `.complete`, route to final. If `.continue`, route to executor. If `.replan`, route to executor with feedback.

| Step | Status | Effort |
|---|---|---|
| Create minimal `TaskPlan` for plan-less execution | ❌ TODO | 1 hr |
| Wire `OrchestrationReviewerNode` into graph | ❌ TODO | 1 hr |
| Replace `BranchReviewNode` signal routing with `ReviewDecision` | ❌ TODO | 2 hr |
| Wire `ExecutionResult` from `ToolLoopNode` to `ReviewerNode` | ❌ TODO | 1 hr |
| Test: verify routing works end-to-end | ❌ TODO | 2 hr |

**Key decision:** The `TaskPlan` requirement. `PlanCompletenessStrategy` needs a plan to check against. For executions without an explicit plan, we need either:
- **Option A:** Create a minimal plan from the user's input (single step: "Fulfill the request") — simple but provides no granularity
- **Option B:** Call the model to produce a structured plan before execution (PlannerNode) — correct but requires an LLM call
- **Option C:** Use a `CompletionSignalStrategy` that just checks "did the model produce tool calls?" — simplest but least informative

**Recommendation:** Option A for Phase 2, Option B for Phase 3.

### Phase 3: Remove Stall Detection from ToolLoopHandler

**What:** Now that the `ReviewerNode` handles completion detection, remove the 11 heuristic stall detectors from `ToolLoopHandler`. The handler becomes a pure executor: call LLM → extract tools → execute → return results.

| Stall detector | Lines | Removal risk |
|---|---|---|
| Post-mutation write stall | 30 | Low — ReviewDecision handles this |
| Unavailable tool stall | 25 | Low — model self-corrects |
| Repeated completed signatures | 40 | Low — ReviewDecision.continue handles this |
| Repeated write target | 20 | Low — ReviewDecision.replan handles this |
| Read-only stall | 30 | Low — ReviewDecision.continue handles this |
| Repeated batch stall | 15 | Low — ReviewDecision handles this |
| Wall-clock convergence (RC6) | 20 | Low — not needed |
| Reads-without-mutation (RC6) | 20 | Low — not needed |
| Non-recoverable mutation failure | 15 | Low — ReviewDecision.replan handles this |
| Repeated no-tool-call content | 25 | Low — not needed (no tool calls = complete) |
| Empty response stall | 15 | Low — not needed (empty = complete with no work) |
| **Total removed** | **~255 lines** | |

**Net reduction in ToolLoopHandler:** ~255 lines removed. The handler shrinks from 3293 to ~3038 lines.

### Phase 4: PlannerNode (future — optional)

**What:** Before execution, the model produces a structured `TaskPlan`. The plan has named steps with descriptions. The `PlanCompletenessStrategy` checks each step against the `ExecutionResult`. This provides granular completion tracking.

**Not required for the immediate fix.** The `PlanCompletenessStrategy` with a minimal plan (Phase 2, Option A) is sufficient.

---

## Design Decisions

### Decision 1: Graph topology stays (no nodes removed)

**Don't remove `EmptyResponseRecoveryNode` or `BranchReviewNode`.** They serve valid purposes for abnormal termination (stall, max iterations, empty response). The routing change (`modelChoseToStop → direct to final`) bypasses them during normal operation. They remain as safety nets for edge cases.

### Decision 2: `modelChoseToStop` is a state flag, not a Transition type

The flag lives in `OrchestrationState` and propagates through `updating()`. This is simpler than creating a new `Transition` variant (which would require changing the graph runner). The flag is checked in `FinalResponseNode` to skip re-prompt.

### Decision 3: `TaskPlan` created minimally, not via PlannerNode

Creating the plan via a PlannerNode LLM call adds latency and complexity. A minimal plan (single step: "Fulfill the user's request") works with `PlanCompletenessStrategy` because the strategy only checks "were all steps completed?" — with one step, this becomes "was the request fulfilled?" which the model already answered by choosing to stop calling tools.

### Decision 4: ReviewStrategy defaults to PlanCompletenessStrategy

`PlanCompletenessStrategy` is deterministic (no LLM call), fast, and sufficient for the immediate fix. `SelfReflectionStrategy` (which calls the LLM) can be added later for deeper quality evaluation.

---

## Success Criteria

| Criterion | Current | Target | Measurement |
|---|---|---|---|
| Phase 1 completion | 60s timeout | **≤5s** after last tool call | Harness log |
| Phase 2 tool execution | Intermittent | **Always** executes tools | Harness check |
| Phase 2 completion | 60s timeout | **≤5s** after last tool call | Harness log |
| All assertions pass | Intermittent (run 7) | **Always** (6/6) | Harness check |
| Total run time | 208s (best) | **≤120s** | Harness duration |
| No LLM calls after completion | Calls re-prompt | **Zero** post-completion LLM calls | AppLogger trace |

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `modelChoseToStop` lost in struct copy | Low (documented, fixed) | Flag in `updating()` + init + direct state access |
| Model produces tool calls after "completion" | Low (model is deterministic) | Tool loop re-enters naturally, modelChoseToStop resets |
| Minimal plan too coarse for review | Medium | Phase 3 adds PlannerNode if needed |
| BranchReviewNode conflicts with ReviewerNode | Low | BranchReviewNode only reached on abnormal termination |
