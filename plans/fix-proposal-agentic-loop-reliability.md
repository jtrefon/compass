# Architecture Proposal: Agentic Loop Reliability v2

## Design Principles Applied

| Principle | Application |
|---|---|
| **SRP** | Each node has exactly one job: plan, execute, or review |
| **OCP** | New review strategies plug in via protocol conformance — zero orchestrator changes |
| **LSP** | All nodes implement `AgentPipelineNode` — any node can replace any other |
| **ISP** | Nodes depend on `AgentProtocol` (context + tools), not on concrete types |
| **DIP** | Orchestrator depends on `AgentPipelineNode` protocols, never on concrete nodes |
| **DRY** | Shared path resolution, state serialization, decision routing — one implementation |
| **KISS** | Three-node pipeline with one routing edge. Not a DAG — a state machine with 3 states |
| **YAGNI** | No sub-agents, no parallel execution, no complex graph traversal. Not building LangGraph |

---

## Architectural Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    AgentOrchestrator                             │
│  (mediator — owns lifecycle, routes between nodes)               │
│                                                                  │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐                     │
│  │ Planner  │ → │ Executor │ → │ Reviewer │                     │
│  └──────────┘   └──────────┘   └────┬─────┘                     │
│       ↑                              │                           │
│       └────────── continue ──────────┘                           │
│                                                                  │
│  State: { conversationId, plan, currentPhase, error, result }   │
└─────────────────────────────────────────────────────────────────┘
```

The orchestrator maintains a single `AgentState` value object that flows through the pipeline. Each node reads the state, performs its work, and returns a transition instruction. The orchestrator applies the transition and routes accordingly.

---

## Design Pattern: State Machine (not fixed loop)

The current architecture uses a **fixed loop**: call LLM → execute tools → call LLM → execute tools → ...until timeout. The model has no structured way to say "I'm done."

The proposed architecture uses a **state machine** where the model declares its intent via structured output:

```
                  ┌──────────────────────────────┐
                  │         IDLE                  │
                  └──────────┬───────────────────┘
                             │ sendMessage()
                             ▼
                  ┌──────────────────────────────┐
                  │        PLANNING               │
                  │  Model creates TaskPlan        │
                  └──────────┬───────────────────┘
                             │ plan complete
                             ▼
                  ┌──────────────────────────────┐
                  │        EXECUTING              │
                  │  Tool calls → results          │
                  └──────────┬───────────────────┘
                             │ tool batch done
                             ▼
                  ┌──────────────────────────────┐
                  │        REVIEWING              │
                  │  Model evaluates progress      │
                  └──┬───────────────┬───────────┘
                     │               │
             continue/refine    complete/blocked
                     │               │
                     ▼               ▼
              ┌──────────┐   ┌──────────────┐
              │ PLANNING  │   │   COMPLETE   │
              │ (refine)  │   │ or FAILED    │
              └──────────┘   └──────────────┘
```

**Key difference:** The model transitions between states via **structured output**, not via the framework guessing. The model says "I am done executing" (Review → Complete), and the framework believes it.

---

## Core Types

### 1. AgentPhase — State enum

```swift
enum AgentPhase: Sendable {
    case idle
    case planning(TaskPlan)
    case executing(plan: TaskPlan, completedSteps: [String])
    case reviewing(plan: TaskPlan, executionResult: ExecutionResult)
    case complete(Result)
    case failed(Error)
}
```

This is a **value type** — immutable, sendable, replaceable. The orchestrator snapshots it at every transition.

### 2. TaskPlan — Structured plan from the model

```swift
struct TaskPlan: Sendable, Codable {
    let goal: String
    let steps: [PlanStep]
    let estimatedDifficulty: Difficulty

    struct PlanStep: Sendable, Codable {
        let id: String
        let description: String
        let action: StepAction
        let dependsOn: [String]
    }

    enum StepAction: Sendable, Codable {
        case createFile(path: String)
        case editFile(path: String, description: String)
        case runCommand(description: String)
        case search(description: String)
        case read(description: String)
        case custom(description: String)
    }
}
```

The model produces this via `tool_use` (structured output). The framework never parses free text for plans.

### 3. ReviewDecision — Structured completion signal

```swift
enum ReviewDecision: Sendable {
    /// The plan is complete. Include a summary for the user.
    case complete(summary: String)
    /// Progress was made but more work is needed. Continue executing.
    case continueExecuting(updatedPlan: TaskPlan?)
    /// The current approach isn't working. Re-plan with this feedback.
    case needsReplan(feedback: String)
    /// Blocked — cannot proceed without user input or external change.
    case blocked(reason: String)
}
```

This is the **core innovation**. The model produces this decision as a structured tool call after each execution batch. The framework reads it and routes accordingly. No guessing, no timeouts.

### 4. AgentState — Immutable value object

```swift
struct AgentState: Sendable {
    let conversationId: String
    let phase: AgentPhase
    let plan: TaskPlan?
    let turnCount: Int
    let totalToolCalls: Int
    let errors: [AgentError]
    let createdAt: Date
}
```

---

## Design Pattern: Strategy (Pluggable Reviewers)

The review phase has multiple strategies, selectable at construction time:

```swift
protocol ReviewStrategy: Sendable {
    func evaluate(
        plan: TaskPlan,
        executionResult: ExecutionResult,
        context: AgentContext
    ) async -> ReviewDecision
}
```

Concrete strategies:

```swift
/// The model reviews its own work via structured tool call
struct SelfReflectionReview: ReviewStrategy { ... }

/// A separate lightweight model evaluates the executor's output
/// (Anthropic Advisor pattern)
struct AdvisorReview: ReviewStrategy {
    let advisorModel: AIService  // lighter, cheaper model
}

/// Simple check: were all planned steps executed successfully?
struct PlanCompletenessReview: ReviewStrategy {
    func evaluate(...) async -> ReviewDecision {
        let allDone = plan.steps.allSatisfy { step in
            executionResult.completedSteps.contains(step.id)
        }
        return allDone ? .complete(summary: "...") : .continueExecuting()
    }
}
```

**SRP:** Each strategy has one job — evaluate completion.
**OCP:** Add new strategies without modifying the orchestrator.
**ISP:** Strategy depends only on `(plan, result, context)`, not on the full pipeline.

---

## Design Pattern: Proxy (Path Abstraction)

Current problem: Model writes to `/workspace/package.json` instead of the real path.

Solution: The tool layer acts as a **proxy** that the model never sees through:

```
Model: write("package.json", content)
  → ToolProxy.resolve("package.json")
  → PathResolver.canonical("package.json")
  → "/var/.../UUID/package.json"
  → Sandbox.validate(...) → OK
  → FileManager.write(...)
```

```swift
protocol PathResolving: Sendable {
    func canonical(_ relativePath: String) -> String
    func relative(_ absolutePath: String) -> String
    var sandboxRoot: String { get }
}

final class SandboxPathResolver: PathResolving {
    private let root: String  // injected at init, never changes

    init(sandboxRoot: String) {
        self.root = sandboxRoot
    }

    func canonical(_ relativePath: String) -> String {
        guard !relativePath.hasPrefix("/") else {
            // Model passed an absolute path — resolve relative to sandbox root
            return (root as NSString).appendingPathComponent(
                String(relativePath.dropFirst())
            )
        }
        return (root as NSString).appendingPathComponent(relativePath)
    }

    /// The sandbox root is the single source of truth for all paths
    var sandboxRoot: String { root }
}
```

**Key insight:** The model **never sees an absolute path** in tool results. All paths returned by tools are passed through `PathResolver.relative()` which strips the sandbox root prefix. The model only ever sees `src/App.jsx`, never `/var/folders/.../src/App.jsx`. This prevents path memorization and hallucination.

The sandbox root is injected into the **system prompt** once (not per-tool-call):

```
Project root: {sandboxRoot}
All file paths use relative notation (e.g., "src/main.jsx" not "/absolute/path/src/main.jsx").
```

---

## Design Pattern: Memento (Clean Continuation)

Current problem: `stopGeneration()` leaves pipeline in half-stopped state. Next `sendMessage()` gets corrupted context.

Solution: Each message turn starts from a **clean state** assembled from the persisted conversation history:

```swift
/// Before starting a new turn, snapshot the agent state
final class ConversationManager {
    private var stateHistory: [AgentState] = []

    func sendMessage() {
        // Snapshot current state before modifying
        let snapshot = currentState
        stateHistory.append(snapshot)

        // Reset pipeline for fresh turn
        pipeline.reset()

        // Assemble context from persisted history, not from pipeline state
        let context = contextAssembler.assemble(
            from: conversationStore.allTurns(),
            systemPrompt: systemPrompt,
            sandboxRoot: pathResolver.sandboxRoot
        )

        // Start fresh turn
        pipeline.execute(context: context)
    }

    func stopGeneration() {
        pipeline.cancel()
        // Restore to pre-turn snapshot
        if let lastState = stateHistory.last {
            restoreState(lastState)
            stateHistory.removeLast()
        }
    }
}
```

**Key principle:** The pipeline is ephemeral — rebuilt per turn. The conversation store is the durable source of truth. If a turn fails, the next turn reassembles context from the store, not from the broken pipeline.

---

## Design Pattern: Mediator (AgentOrchestrator)

The orchestrator is a **mediator** — it doesn't execute work, it coordinates:

```swift
actor AgentOrchestrator {
    private let planner: PlannerNode
    private let executor: ExecutorNode
    private let reviewer: ReviewerNode
    private let pathResolver: PathResolving
    private let stateStore: StateStore

    func execute(prompt: String) async throws -> AgentResult {
        var state = AgentState(conversationId: UUID().uuidString)

        // 1. Plan
        let plan = try await planner.createPlan(for: prompt)
        state = state.transition(to: .executing(plan: plan))

        // 2. Execute → Review loop
        while true {
            let result = try await executor.execute(plan: state.plan!)
            state = state.transition(to: .reviewing(result: result))

            let decision = try await reviewer.evaluate(
                plan: state.plan!,
                result: result
            )

            switch decision {
            case .complete(let summary):
                return AgentResult(summary: summary, state: state)
            case .continueExecuting(let updatedPlan):
                state = state.transition(to: .executing(
                    plan: updatedPlan ?? state.plan!
                ))
            case .needsReplan(let feedback):
                let revisedPlan = try await planner.revisePlan(
                    basedOn: feedback
                )
                state = state.transition(to: .executing(plan: revisedPlan))
            case .blocked(let reason):
                return AgentResult(
                    error: AgentError.blocked(reason: reason),
                    state: state
                )
            }
        }
    }
}
```

**SRP:** The orchestrator only routes. Planning, execution, and review are separate nodes.
**DIP:** The orchestrator depends on `PlannerNode`, `ExecutorNode`, `ReviewerNode` protocols, not concrete implementations.
**DRY:** The routing logic is in one place (the switch statement), not scattered across the tool loop.

---

## Pipeline Node Protocols

```swift
protocol PlannerNode: Sendable {
    func createPlan(for prompt: String) async throws -> TaskPlan
    func revisePlan(basedOn feedback: String) async throws -> TaskPlan
}

protocol ExecutorNode: Sendable {
    func execute(plan: TaskPlan) async throws -> ExecutionResult
}

protocol ReviewerNode: Sendable {
    func evaluate(
        plan: TaskPlan,
        result: ExecutionResult
    ) async throws -> ReviewDecision
}
```

These are intentionally minimal — each node does one thing, and one thing only. The executor doesn't decide when it's done. The reviewer doesn't plan. The planner doesn't execute tools.

---

## How Each Issue Is Resolved

| Issue | Root Cause | Architecture Fix | Pattern |
|---|---|---|---|
| **Post-execution dropout** | Fixed loop has no completion signal | Review node produces structured `ReviewDecision`. Loop terminates when model says "complete" | State Machine |
| **Path hallucination** | Model guesses absolute paths | `PathResolver` proxy mediates all path translation. Model sees relative paths only | Proxy |
| **Context corruption on stop** | Pipeline state leaks between turns | Each turn assembles context from persisted store. Pipeline is ephemeral. `stopGeneration()` restores pre-turn snapshot | Memento |
| **No progress visibility** | Loop doesn't know what the model is doing | `TaskPlan` with named steps. `ExecutionResult` tracks completed/remaining steps. Orchestrator can emit progress events | Value Object |
| **Tool call loops (same tool repeated)** | No structural feedback to model | Review node can detect "repeated same step" and return `.needsReplan` with feedback. Same as LangGraph's "loop detection" | Strategy |

---

## Existing Code Alignment

This architecture builds on existing infrastructure — not replacement:

| New concept | Maps to existing code |
|---|---|
| `AgentState` | `OrchestrationRunSnapshot` (already has snapshots) |
| `ConversationStreamStore` | Already the durable conversation store |
| `ExecutorNode` | Existing `AIToolExecutor` + `ToolLoopHandler` |
| `AgentPhase` | Existing `AIMode` enum (extend, not replace) |
| `ReviewDecision` | New — but parallels existing `QAReviewHandler` |
| `PathResolver` | New — but parallels existing `Sandbox` path validation |
| `AgentOrchestrator` | Existing `ConversationManager` (refactor, not replace) |

---

## Implementation Order (YAGNI-aware)

Only build what's needed now:

### Phase 1 (P0 — path fix)
- Create `PathResolver` with sandbox root injection
- Wire into tool execution layer (proxy pattern)
- Inject sandbox root into system prompt
- **Existing loop untouched**

### Phase 2 (P0 — continuation fix)
- Add state snapshot/restore to `ConversationManager`
- Rebuild context from store on each `sendMessage()`
- **Pipeline unchanged, orchestrator unchanged**

### Phase 3 (P1 — structured completion)
- Add `TaskPlan` structured output (tool_use from model)
- Add `ReviewDecision` structured output
- Add `ReviewStrategy` protocol
- Implement `SelfReflectionReview` strategy
- Wire routing into tool loop
- **Phase 1 + 2 infrastructure used**

### Phase 4 (P2 — state machine)
- Formalize `AgentState` + phase machine
- Implement `AgentOrchestrator`
- Migrate from fixed loop to state-machine routing
- **Phase 3 components reused**

---

## What This Enables Long-Term

- **Pluggable reviewers**: swap `SelfReflectionReview` for `AdvisorReview` (cheaper model) without touching orchestrator
- **Observability**: `AgentState` transitions are natural telemetry events → emit them on `EventBus`
- **Human-in-the-loop**: `ReviewDecision.blocked` is a natural pause point for user intervention
- **Checkpoint/restore**: `AgentState` is serializable → persist snapshots to `.ide/orchestration/` (already done!)
- **Parallel branches**: Not needed now (YAGNI), but the state machine could support concurrent plans if ever needed
