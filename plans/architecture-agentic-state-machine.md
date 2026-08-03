# Architecture Spec: Plan→Execute→Review Agentic State Machine

## Context

**Date:** 2026-07-15
**Decision:** Re-architect from fixed tool loop to structured state machine
**Status:** Design phase — spec for implementation

### Key discovery

The codebase **already has** a full graph orchestration system:
- `OrchestrationNode` protocol — composable, isolated units
- `OrchestrationGraphRunner` — drives transitions, enforces limits
- `OrchestrationState` — explicit state passing through nodes
- `OrchestrationRunSnapshot` — telemetry after every transition
- `ConversationFlowGraphFactory` — wires the graph topology

What exists is an **execution graph**. What we need is a **decision graph** — where the model produces structured output that drives routing, rather than the framework using heuristics to guess what the model wants.

### The gap

| Area | Current | Target |
|---|---|---|
| **Completion detection** | 11 heuristic stall detectors + content keyword matching | Structured `ReviewDecision` tool_use from model |
| **Execution loop** | `ToolLoopHandler` handles both execution AND termination | `ExecutorNode` handles ONLY execution. Reviewer handles termination. |
| **Planning** | Plans created on-the-fly, embedded in conversation | `PlannerNode` produces structured `TaskPlan` before execution |
| **Review** | `QAReviewHandler` is advisory-only, never loops back | Reviewer returns `ReviewDecision` that drives routing |
| **Branch routing** | `BranchReviewNode` uses deprecated `BranchExecutionContinuationDecider` | Branch routing derives from structured `ReviewDecision` |

---

## Architecture Overview

### Graph topology (target)

```
                    ┌──────────────────────────────────────┐
                    │         ConversationSendCoordinator    │
                    │         (entry point, unchanged)       │
                    └──────────────┬───────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────┐
                    │         OrchestrationGraphRunner      │
                    │  (unchanged — drives any graph)       │
                    └──────────────┬───────────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
     ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
     │ PlannerNode  │   │ ExecutorNode │   │ ReviewerNode │
     │ (new)        │   │ (refactored) │   │ (refactored) │
     └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
            │                  │                   │
            └──────────────────┼───────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   BranchReviewNode   │
                    │  (rewired — drives   │
                    │   routing via         │
                    │   ReviewDecision)     │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        ┌──────────┐   ┌────────────┐   ┌──────────────┐
        │ Complete │   │ Continue   │   │  Replan      │
        │ → End    │   │ → Executor │   │ → Planner    │
        └──────────┘   └────────────┘   └──────────────┘
```

### Key principle: separation of concerns

| Node | Responsibility | Pattern |
|---|---|---|
| **PlannerNode** | Produce `TaskPlan` from user request | Strategy (pluggable plan formats) |
| **ExecutorNode** | Execute tools. No termination logic. | Single Responsibility |
| **ReviewerNode** | Evaluate execution result, produce `ReviewDecision` | Strategy (pluggable review strategies) |
| **BranchReviewNode** | Route based on `ReviewDecision` | Mediator (routes, doesn't execute) |

---

## 1. ReviewDecision — Structured Completion Signal

This is the **core innovation**. The model produces this via `tool_use` (structured output), replacing all heuristic stall detectors.

```swift
/// Structured signal from the model indicating what should happen next.
/// Produced by the model as a tool_use call — NOT parsed from free text.
public enum ReviewDecision: Sendable, Codable {
    /// The task is complete. Include a summary for the user.
    case complete(summary: String)

    /// Progress was made. Continue executing with optional plan update.
    case `continue`(updatedPlan: TaskPlan?)

    /// The current approach isn't working. Re-plan with this feedback.
    case replan(feedback: String)

    /// Blocked — cannot proceed without user input.
    case blocked(reason: String, suggestedAction: String?)
}
```

### Design rationale

**Why tool_use and not free-text parsing:**
- Free-text parsing is fragile: the model can say "I'm done" in infinite ways
- `tool_use` guarantees structured, parseable output
- The model is trained to produce correct JSON for tools
- No heuristics, no keyword matching, no content sniffing

**Why an enum and not a boolean:**
- The model needs more than "done/not done" — it needs to express intent
- "Continue" with an updated plan allows the model to refine mid-execution
- "Replan" with feedback prevents infinite loops on failing approaches
- "Blocked" enables human-in-the-loop without a separate mechanism

```swift
/// Strategy protocol — allows swapping review approaches
public protocol ReviewStrategy: Sendable {
    /// Given the execution result and context, produce a decision.
    func evaluate(
        plan: TaskPlan,
        result: ExecutionResult,
        context: AgentContext
    ) async throws -> ReviewDecision
}
```

### Concrete strategies

```swift
/// The model evaluates its own progress via structured tool_use.
public final class SelfReflectionStrategy: ReviewStrategy {
    public func evaluate(
        plan: TaskPlan,
        result: ExecutionResult,
        context: AgentContext
    ) async throws -> ReviewDecision {
        // Construct a review prompt asking the model to self-evaluate
        // The model responds with a ReviewDecision tool_use call
        let prompt = ReviewPrompt(
            plan: plan,
            completedSteps: result.completedSteps,
            failedSteps: result.failedSteps,
            toolCallHistory: result.toolCallHistory
        )
        return try await context.llm.requestStructured(
            prompt: prompt,
            responseType: ReviewDecision.self
        )
    }
}

/// A separate lightweight model evaluates the executor's output.
/// (Anthropic Advisor pattern — pairs fast executor with smart reviewer)
public final class AdvisorReviewStrategy: ReviewStrategy {
    private let advisorService: AIService  // cheaper, faster model

    public func evaluate(
        plan: TaskPlan,
        result: ExecutionResult,
        context: AgentContext
    ) async throws -> ReviewDecision {
        // Reviewer model gets condensed context + tool results
        // Executor model focuses on tool execution only
        let prompt = ReviewPrompt(
            plan: plan,
            completedSteps: result.completedSteps,
            failedSteps: result.failedSteps,
            toolCallHistory: result.toolCallHistory
        )
        return try await advisorService.requestStructured(
            prompt: prompt,
            responseType: ReviewDecision.self
        )
    }
}

/// Deterministic check: were all planned steps executed?
public final class PlanCompletenessStrategy: ReviewStrategy {
    public func evaluate(
        plan: TaskPlan,
        result: ExecutionResult,
        context: AgentContext
    ) async throws -> ReviewDecision {
        let allSucceeded = plan.steps.allSatisfy { step in
            result.completedSteps.contains(step.id)
        }
        let anyFailed = plan.steps.contains { step in
            result.failedSteps.contains(step.id)
        }

        if allSucceeded {
            return .complete(summary: "All \(plan.steps.count) steps completed successfully.")
        }
        if anyFailed {
            return .replan(feedback: "Some steps failed. Review and adjust approach.")
        }
        return .continue(updatedPlan: nil)
    }
}
```

**OCP:** New strategies conform to `ReviewStrategy`. The orchestrator never changes.
**ISP:** Strategy depends only on `(plan, result, context)`, not on the full pipeline.
**SRP:** Each strategy has one job — evaluate execution.

---

## 2. TaskPlan — Structured Plan

The plan is produced by the model as structured output in the planning phase, not parsed from markdown.

```swift
public struct TaskPlan: Sendable, Codable {
    public let goal: String
    public let steps: [PlanStep]
    public let estimatedDifficulty: Difficulty

    public struct PlanStep: Sendable, Codable, Identifiable {
        public let id: String          // "step-1", "step-2"
        public let description: String // "Create package.json"
        public let action: StepAction
        public let dependsOn: [String] // IDs of steps that must complete first

        public enum StepAction: Sendable, Codable {
            case createFile(path: String)
            case editFile(path: String, description: String)
            case runCommand(description: String)
            case search(description: String)
            case read(description: String)
            case custom(description: String)
        }
    }

    public enum Difficulty: String, Sendable, Codable {
        case simple
        case moderate
        case complex
    }
}

/// Tracks which steps have been executed and their results.
public struct ExecutionResult: Sendable, Codable {
    public let planId: String
    public let completedSteps: [String]       // step IDs
    public let failedSteps: [String: String]  // step ID → error
    public let toolCallHistory: [ToolCallRecord]
    public let artifacts: [String: String]    // path → content summary
    public let startedAt: Date
    public let duration: TimeInterval
}
```

### Why structured and not markdown

The current codebase has a deprecated `ConversationPlanStore` that stores plans as markdown strings. The model writes markdown plans, the framework parses them. This is fragile — markdown has no schema, no type safety, no validation.

Structured plan via `tool_use`:
- Guaranteed parseable (the model produces valid JSON)
- Type-safe (Swift enums for actions, dependencies)
- Machine-readable (framework can check step completion without NLP)
- Human-readable (same data can be rendered as markdown for the user)
- Serializable (Codable → JSONL snapshots)

### Integration with existing code

The existing `ConversationPlanStore` has methods `setPlan(conversationId:plan:)` and `getPlan(conversationId:)` that already accept `TaskPlan` (the structured type). The deprecated `set(conversationId:plan:)` / `get(conversationId:)` string-based methods should be removed.

---

## 3. PlannerNode — Dedicated Planning Phase

```swift
public protocol PlannerNode: Sendable {
    func createPlan(for prompt: String, context: AgentContext) async throws -> TaskPlan
    func revisePlan(plan: TaskPlan, feedback: String, context: AgentContext) async throws -> TaskPlan
}

public struct OrchestrationPlannerNode: OrchestrationNode {
    public let id: String = "planner"

    public func run(state: OrchestrationState) async throws -> OrchestrationState {
        guard state.phase == .planning else { return state }

        let plan = try await planner.createPlan(
            for: state.request.userInput,
            context: AgentContext(
                llm: aiInteractionCoordinator,
                tools: state.request.availableTools,
                projectRoot: state.request.projectRoot
            )
        )

        var newState = state
        newState.plan = plan
        newState.phase = .executing
        newState.transition = OrchestrationState.Transition(nextNodeId: ExecutorNode.id)
        return newState
    }
}
```

**SRP:** The planner only plans. It doesn't execute tools or review results.

---

## 4. ExecutorNode — Pure Execution (Refactored from ToolLoopHandler)

The current `ToolLoopHandler` does two things:
1. Executes tools (the actual work)
2. Detects completion (11 heuristic stall detectors)

**The refactoring:** Split these into two nodes. `ExecutorNode` handles #1 only. `ReviewerNode` handles #2.

```swift
public protocol ExecutorNode: Sendable {
    func execute(
        plan: TaskPlan,
        context: AgentContext
    ) async throws -> ExecutionResult
}

public struct OrchestrationExecutorNode: OrchestrationNode {
    public let id: String = "executor"

    public func run(state: OrchestrationState) async throws -> OrchestrationState {
        guard state.phase == .executing, let plan = state.plan else {
            return state
        }

        let result = try await toolLoopHandler.executeTools(
            plan: plan,
            availableTools: state.request.availableTools,
            conversationId: state.request.conversationId
        )

        var newState = state
        newState.executionResult = result
        newState.phase = .reviewing
        newState.transition = OrchestrationState.Transition(nextNodeId: ReviewerNode.id)
        return newState
    }
}
```

### What happens to the current ToolLoopHandler logic:

| Current logic | Destination |
|---|---|
| Tool execution (call LLM → parse tool calls → execute → repeat) | Stays in `ToolLoopHandler` |
| Stall detection (11 detectors) | **Removed** — replaced by `ReviewerNode` |
| Repeated call deduplication | Stays — still valuable within a single execution batch |
| Read caching | Stays |
| Tool failure recovery messages | Stays — the executor still provides feedback to the model |
| Completion keyword matching ("done", "finished") | **Removed** — replaced by `ReviewDecision` |
| Focused execution messages | Stays — still used for getting model back on track |
| Recursive re-entry | **Removed** — routing done by the graph, not by the handler itself |

### Impact on ToolLoopHandler

The handler simplifies from **3236 lines → ~1500 lines**. Removing:
- All stall detection logic (~500 lines)
- All completion heuristics (~300 lines)
- All post-loop recovery logic (~200 lines)
- Recursive re-entry logic (~100 lines)

What remains: tool execution, deduplication, caching, failure recovery messages.

---

## 5. ReviewerNode — Structured Review (Refactored from BranchReviewNode + QAReviewHandler)

```swift
public protocol ReviewerNode: Sendable {
    func evaluate(
        plan: TaskPlan,
        result: ExecutionResult,
        context: AgentContext,
        strategy: ReviewStrategy
    ) async throws -> ReviewDecision
}

public struct OrchestrationReviewerNode: OrchestrationNode {
    public let id: String = "reviewer"

    private let strategy: ReviewStrategy  // injected — pluggable

    public func run(state: OrchestrationState) async throws -> OrchestrationState {
        guard state.phase == .reviewing,
              let plan = state.plan,
              let result = state.executionResult else {
            return state
        }

        let decision = try await evaluator.evaluate(
            plan: plan,
            result: result,
            context: AgentContext(
                llm: aiInteractionCoordinator,
                tools: state.request.availableTools,
                projectRoot: state.request.projectRoot
            ),
            strategy: strategy
        )

        var newState = state
        newState.reviewDecision = decision

        switch decision {
        case .complete:
            newState.phase = .complete
            newState.transition = OrchestrationState.Transition(nextNodeId: FinalResponseNode.id)
        case .continue(let updatedPlan):
            newState.plan = updatedPlan ?? state.plan
            newState.phase = .executing
            newState.transition = OrchestrationState.Transition(nextNodeId: ExecutorNode.id)
        case .replan(let feedback):
            newState.phase = .planning
            newState.replanFeedback = feedback
            newState.transition = OrchestrationState.Transition(nextNodeId: PlannerNode.id)
        case .blocked:
            newState.phase = .blocked
            newState.transition = OrchestrationState.Transition(nextNodeId: FinalResponseNode.id)
        }

        return newState
    }
}
```

**The routing is explicit:** The `ReviewDecision` drives `nextNodeId`. No heuristics, no content sniffing, no stall detectors.

---

## 6. BranchReviewNode — Rewired (Not Replaced)

The current `BranchReviewNode` uses `BranchExecutionContinuationDecider` (deprecated). Replace the decider with `ReviewDecision` routing.

The node itself stays — its role as a "router" is correct. Only the decision logic changes:

```swift
// Before (current):
continuationDecider.shouldContinue(state: state)
  // ← uses deprecated BranchExecutionContinuationDeciding protocol
  // ← heuristics on content + signals

// After (target):
let decision = state.reviewDecision
switch decision {
  case .continue: route to ExecutorNode
  case .replan:   route to PlannerNode
  case .complete: route to FinalResponseNode
  case .blocked:  route to FinalResponseNode (with blocked flag)
}
```

---

## 7. Graph Wiring — ConversationFlowGraphFactory

Current wiring:
```
dispatcher → tool_loop → empty_response_recovery → branch_review → final_response → [QA]
```

Target wiring:
```
planner → executor → reviewer → branch_review
             ↑                    │
             └──── continue ──────┘
```

```swift
public extension ConversationFlowGraphFactory {
    static func makeStateMachineGraph(
        planner: PlannerNode,
        executor: ExecutorNode,
        reviewer: ReviewerNode,
        finalResponse: FinalResponseHandler,
        qaEnabled: Bool
    ) -> OrchestrationGraph {
        var nodes: [OrchestrationNode] = []

        let plannerNode = OrchestrationPlannerNode(planner: planner, nextNodeId: ExecutorNode.id)
        let executorNode = OrchestrationExecutorNode(executor: executor, nextNodeId: ReviewerNode.id)
        let reviewerNode = OrchestrationReviewerNode(
            evaluator: reviewer,
            nextNodeId: BranchReviewNode.id
        )
        let branchNode = OrchestrationBranchReviewNode(
            executorNodeId: ExecutorNode.id,
            plannerNodeId: PlannerNode.id,
            finalNodeId: FinalResponseNode.id
        )
        let finalNode = OrchestrationFinalResponseNode(
            handler: finalResponse,
            nextNodeId: qaEnabled ? QAToolOutputReviewNode.id : nil
        )

        if qaEnabled {
            nodes = [plannerNode, executorNode, reviewerNode, branchNode, finalNode,
                     QAToolOutputReviewNode(...), QAQualityReviewNode(...)]
        } else {
            nodes = [plannerNode, executorNode, reviewerNode, branchNode, finalNode]
        }

        return OrchestrationGraph(nodes: nodes)
    }
}
```

---

## 8. Integration with Existing Types

| New concept | Maps to existing |
|---|---|
| `ReviewDecision` | New — but the `Review` concept exists in `BranchReviewNode` |
| `TaskPlan` | Replaces `ConversationPlanStore` string-based `set/get` |
| `ReviewStrategy` | New protocol — `SelfReflectionStrategy` uses existing `AIInteractionCoordinator` |
| `PlannerNode` protocol | New — but `PlanTool` already has planning logic |
| `ExecutorNode` protocol | Refactors `ToolLoopHandler.executeTools()` from the existing handler |
| `ReviewerNode` protocol | Refactors `BranchReviewNode.decide()` + `QAReviewHandler` |
| `OrchestrationPlannerNode` | Extends `OrchestrationNode` (existing protocol) |
| `OrchestrationExecutorNode` | Extends `OrchestrationNode` (existing protocol) |
| `OrchestrationReviewerNode` | Extends `OrchestrationNode` (existing protocol) |

---

## 9. How Each Issue Is Resolved

| Current problem | How the architecture fixes it |
|---|---|
| **Post-execution dropout** (Phase 1) | Executor finishes → Reviewer evaluates. If model says `.complete`, routing goes to `FinalResponseNode` immediately. No 60s wait. |
| **Context corruption on continuation** (Phase 2) | Each turn is a fresh graph run. The graph state is explicit (`OrchestrationState`), not embedded in the pipeline. `stopGeneration()` cancels the current run; next `sendMessage()` creates a new graph run from clean state. |
| **Path hallucination** (already fixed) | Not an architecture issue — already fixed via PathValidator. |
| **Tool call loops** | Executor runs tools. Reviewer detects "same step repeated" and returns `.replan` with feedback. The model gets structured guidance instead of guessing. |
| **No plan adherence** | Planner produces structured `TaskPlan` with step IDs. Executor tracks which steps were completed. Reviewer checks plan completeness. |
| **Stall detectors (11 of them)** | Entirely eliminated. The model declares completion via `.complete` or the reviewer strategy determines it. No heuristic stall detection, no content keyword matching, no timeout guessing. |

---

## 10. Implementation Plan

### Phase 1: Foundation (days 1-2)
- Create `ReviewDecision` enum (Codable, Sendable)
- Create `TaskPlan` struct (Codable, Sendable, Identifiable)
- Create `ExecutionResult` struct
- Create `ReviewStrategy` protocol
- Implement `SelfReflectionStrategy`
- Implement `PlanCompletenessStrategy`
- Add these as tools the model can call (`tool_use` definitions)

### Phase 2: Nodes (days 3-4)
- Create `PlannerNode` protocol + `OrchestrationPlannerNode`
- Create `ExecutorNode` protocol + `OrchestrationExecutorNode` (refactors `ToolLoopHandler`)
- Create `OrchestrationReviewerNode`
- Rewire `BranchReviewNode` to use `ReviewDecision`
- Add new graph wiring to `ConversationFlowGraphFactory`

### Phase 3: Integration (days 5-6)
- Wire new graph into `ConversationSendCoordinator`
- Add configuration to select graph topology (legacy vs state machine)
- Remove deprecated `BranchExecutionContinuationDecider`
- Remove deprecated `ConversationPlanStore` string methods
- Update `OrchestrationRunSnapshot` to include `TaskPlan` and `ReviewDecision`

### Phase 4: Testing (day 7)
- Update existing harness tests to validate state machine routing
- Add test for each `ReviewDecision` branch (complete → final, continue → executor, replan → planner, blocked → final)
- Verify `ReviewDecision` is properly serialized in orchestration snapshots
- Re-run `testHarnessReactTodoToSSRRefactor` — Phase 1 should no longer timeout, Phase 2 should execute tools

---

## 11. SOLID Compliance Checklist

| Principle | Compliance |
|---|---|
| **SRP** | PlannerNode plans, ExecutorNode executes, ReviewerNode reviews. Each has exactly one reason to change. |
| **OCP** | New `ReviewStrategy` conformances can be added without modifying any node or the orchestrator. |
| **LSP** | All nodes implement `OrchestrationNode`. Any node can be replaced by any other `OrchestrationNode` conformer. |
| **ISP** | Nodes depend on `PlannerNode`, `ExecutorNode`, `ReviewerNode` protocols — not on concrete implementations. |
| **DIP** | `OrchestrationGraphRunner` depends on `OrchestrationNode` protocol. `ReviewerNode` depends on `ReviewStrategy` protocol. Concrete strategies depend on `AIInteractionCoordinator` protocol. |
| **DRY** | Path resolution is in `PathResolver`. Plan logic is in `TaskPlan`. Review logic is in `ReviewStrategy`. No duplication across nodes. |
| **KISS** | Three nodes, one routing edge, one decision type. Not a DAG — a state machine with 4 states and 4 transitions. |
| **YAGNI** | No sub-agents, no parallel execution, no complex graph traversal. Not building LangGraph — adopting its completion-signal pattern. |

---

## Appendix: What Exists vs What Needs Building

| Component | Status | Action |
|---|---|---|
| `OrchestrationNode` protocol | ✅ Exists | Unchanged |
| `OrchestrationGraphRunner` | ✅ Exists | Unchanged |
| `OrchestrationState` | ✅ Exists | Add `plan`, `executionResult`, `reviewDecision`, `phase` fields |
| `OrchestrationRunSnapshot` | ✅ Exists | Add `plan` and `reviewDecision` fields |
| `ToolLoopHandler` (execution) | ✅ Exists | Refactor to remove stall detection + completion heuristics |
| `ToolLoopHandler` (stall detection) | ❌ Remove entirely | Replaced by `ReviewerNode` |
| `BranchReviewNode` | ✅ Exists | Rewire to use `ReviewDecision` instead of `BranchExecutionContinuationDecider` |
| `ConversationPlanStore` (structured) | ✅ Exists (`setPlan`/`getPlan`) | Keep |
| `ConversationPlanStore` (string) | ❌ Deprecated (`set`/`get`) | Remove |
| `PlanTool` | ✅ Exists | Can be refactored to produce structured `TaskPlan` |
| `QAReviewHandler` | ✅ Exists | Keep as optional quality gate after final response |
| `ReviewDecision` | ❌ Missing | New — this is the core addition |
| `TaskPlan` (structured) | ❌ Missing | New — replaces markdown plans |
| `ReviewStrategy` protocol | ❌ Missing | New — pluggable review approaches |
| `SelfReflectionStrategy` | ❌ Missing | New — model evaluates own work |
| `AdvisorReviewStrategy` | ❌ Missing | New — separate reviewer model |
| `PlannerNode` protocol | ❌ Missing | New — formal planning phase |
| `ExecutorNode` protocol | ❌ Missing | New — formal execution phase |
| `ReviewerNode` protocol | ❌ Missing | New — formal review phase |
| `OrchestrationPlannerNode` | ❌ Missing | New graph node |
| `OrchestrationExecutorNode` | ❌ Missing | New graph node (wraps refactored `ToolLoopHandler`) |
| `OrchestrationReviewerNode` | ❌ Missing | New graph node |
