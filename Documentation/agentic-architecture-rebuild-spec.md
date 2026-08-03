# Agentic Architecture Rebuild — Technical Specification

> **Version:** 1.0
> **Status:** Proposal — not yet implemented
> **Principle:** Zero tech debt. Every line ships or is deleted.
> **Scope:** Replace the current graph-wrapping-loop hybrid with a process-scaling graph architecture.
> **Net delta:** ~9,000 lines deleted, ~610 lines added. 30 files removed, 9 files created, 8 files modified.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Target Architecture](#2-target-architecture)
3. [Request Classifier](#3-request-classifier)
4. [Component Specifications](#4-component-specifications)
   - 4.1 [FastPathNode](#41-fastpathnode)
   - 4.2 [ResearcherNode](#42-researchernode)
   - 4.3 [AnalystNode](#43-analystnode)
   - 4.4 [ArchitectNode](#44-architectnode)
   - 4.5 [ProjectManagerNode](#45-projectmanagernode)
   - 4.6 [LeafExecutorNode](#46-leafexecutornode)
   - 4.7 [LeafReviewNode](#47-leafreviewnode)
   - 4.8 [FinalResponseNode](#48-finalresponsenode)
5. [Graph Topologies](#5-graph-topologies)
6. [Data Structures](#6-data-structures)
7. [Walkthroughs](#7-walkthroughs)
8. [Implementation Plan](#8-implementation-plan)
9. [Cleanup: Delete List](#9-cleanup-delete-list)
10. [Keep List](#10-keep-list)
11. [Testing Strategy](#11-testing-strategy)

---

## 1. Problem Statement

### Current state

The agentic execution system is a **graph wrapping a loop**, both with independent recovery mechanisms:

```
OrchestrationGraphRunner (outer — up to 64 graph transitions)
  └─ ToolLoopNode → ToolLoopHandler.handleToolLoopIfNeeded()
       └─ while-loop (up to 50 internal LLM calls, 22 stall conditions, 6 recovery paths)
            └─ when stalled → ToolLoopResult
                 └─ OrchestrationReviewerNode → "plan not complete" → routes BACK to ToolLoopNode
                      └─ ToolLoopHandler starts ANOTHER 50-iteration loop
```

**Failures observed** (session EA96741C, WordPress project, "review career-register plugin"):

| Metric | Value |
|---|---|
| Tool calls consumed | 64 (20 ls, 16 search, 14 read, 8 bash, 6 glob) |
| Assistant content batches | 22 (18 empty, 2 with intro text) |
| User messages sent | 4 (1 greeting, 2 review requests, 1 retry) |
| Deliverable produced | ZERO — agent never delivered the review |
| Context tokens consumed | 262k (session killed by operator) |

**Root cause:** The graph and the loop both independently decide "should we keep going?" but neither knows what "done" looks like for the user's specific request. The `PlanCompletenessStrategy` exists in the codebase but is never wired because ToolLoopHandler makes all termination decisions inside its internal while-loop.

### Target state

A process-scaling graph where:
- **Simple queries** ("hi", "which port?") → 1 LLM call → respond
- **Reviews/audits** ("review X plugin") → research context → analyse → respond (~6 turns)
- **Build tasks** ("create a form plugin") → full Plan→Break Down→Execute→QA→Review pipeline (20+ turns)

No while-loops inside nodes. No recovery prompt injection. No stall detection. Termination decided by the graph's deterministic `PlanCompletenessStrategy`.

---

## 2. Target Architecture

```
                         ┌─────────────────────────┐
                         │       REQUEST           │
                         │       CLASSIFIER        │   ← new, ~60 lines
                         │  (deterministic, no LLM) │
                         └───────────┬─────────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    ▼                ▼                ▼
         ┌─────────────┐   ┌──────────────┐   ┌──────────────┐
         │  FAST PATH  │   │ REVIEW PATH  │   │  BUILD PATH │
         │  (1 node)   │   │  (3 nodes)   │   │ (8 nodes)   │
         └──────┬──────┘   └──────┬───────┘   └─────┬────────┘
                │                 │                  │
                ▼                 ▼                  ▼
         ┌─────────────┐   ┌──────────────┐   ┌──────────────┐
         │FastPathNode │   │ResearcherNode│   │ResearcherNode│
         │ tools: none │   │ tools: r,s,  │   │ tools: r,s,  │
         │ max: 1 call │   │  ls, glob    │   │  ls, glob    │
         └──────┬──────┘   │ max: 5 iter  │   │ max: 8 iter  │
                │          └──────┬───────┘   └──────┬───────┘
                ▼                 │                  │
         ┌─────────────┐          ▼                  ▼
         │FinalResponse│   ┌──────────────┐   ┌──────────────┐
         │    Node     │   │ AnalystNode  │   │ ArchitectNode│
         └─────────────┘   │ tools: ctx   │   │ tools: r,s,  │
                           │ max: 3 iter  │   │  ctx         │
                           └──────┬───────┘   │ max: 3 iter  │
                                  │           └──────┬───────┘
                                  ▼                  │
                           ┌──────────────┐          ▼
                           │FinalResponse │   ┌──────────────┐
                           │    Node      │   │ ProjectMgrNode│
                           └──────────────┘   │ tools: r, ctx│
                                              │ max: 3 iter  │
                                              │ (visit 1:     │
                                              │  break down)  │
                                              └──────┬───────┘
                                                     │
                                          ┌──────────┼──────────┐
                                          ▼          ▼          ▼
                                    ┌─────────┐┌─────────┐┌─────────┐
                                    │LeafExec ││LeafExec ││LeafExec │
                                    │ tools:  ││ tools:  ││ tools:  │
                                    │  all 9  ││  all 9  ││  all 9  │
                                    │max: 8 it││max: 8 it││max: 8 it│
                                    └────┬────┘└────┬────┘└────┬────┘
                                         │          │          │
                                         ▼          ▼          ▼
                                    ┌─────────┐┌─────────┐┌─────────┐
                                    │LeafRev  ││LeafRev  ││LeafRev  │
                                    │tools: r,││tools: r,││tools: r,│
                                    │  s, ls  ││  s, ls  ││  s, ls  │
                                    │max: 2 it││max: 2 it││max: 2 it│
                                    └────┬────┘└────┬────┘└────┬────┘
                                         │          │          │
                                         └──────────┼──────────┘
                                           (all pass or fail)
                                                    │
                                                    ▼
                                           ┌──────────────┐
                                           │ ProjectMgrNode│
                                           │ tools: r, ctx │
                                           │ max: 3 iter   │
                                           │ (visit 2:     │
                                           │  assembly)    │
                                           └──────┬───────┘
                                                  │
                                    ┌─────────────┼─────────────┐
                                    ▼             ▼             ▼
                              ┌─────────┐  ┌──────────┐  ┌──────────┐
                              │ CORRECT │  │CONTINUE  │  │COMPLETE  │
                              │leaves   │  │next round│  │route to  │
                              └────┬────┘  └──────────┘  │FinalResp │
                                   │                     └────┬─────┘
                                   └──────────┐               │
                                              ▼               ▼
                                       ┌──────────┐   ┌──────────────┐
                                       │LeafExec  │   │FinalResponse │
                                       │(re-run)  │   │    Node      │
                                       └──────────┘   └──────────────┘
```

### Key design rules

1. **No node contains a while-loop for LLM calls.** Each node makes ONE LLM call per visit. The graph's `OrchestrationGraphRunner` handles iteration by routing the node back to itself via `state.transition.nextNodeId`.

2. **No prompt injection for recovery.** Recovery is structural — the graph routes to the correct node with the correct state. No `buildFocusedExecutionMessages`, no `priorWorkSummary`, no recovery system prompts.

3. **All termination decisions are deterministic.** `PlanCompletenessStrategy` checks `TaskPlan.items.filter { $0.status == .completed }.count == TaskPlan.items.count`. No LLM asked "are you done?"

4. **Nodes are stateless functions of `OrchestrationState → OrchestrationState`**. All persistent state lives in the state object, not in node instances.

---

## 3. Request Classifier

**File:** `compass/Services/CloudPipeline/RequestClassifier.swift` (new, ~60 lines)

### Interface

```swift
enum RequestComplexity: String, Sendable {
    case fast       // greeting, factual question — no task to perform
    case review     // read-only analysis, audit, critique, explain
    case build      // create, modify, refactor, implement
}

enum RequestClassifier {
    /// Classify a user input into one of three complexity paths.
    /// Deterministic — no LLM call. Runs in <1ms.
    static func classify(_ userInput: String) -> RequestComplexity
}
```

### Algorithm

```
1. Normalise: lowercase, trim whitespace
2. Extract first sentence (up to first ".", "?", "!", or 200 chars)
3. If sentence matches any fastPathSignal → return .fast
4. If sentence matches any reviewPathSignal AND no mutationSignal → return .review
5. Default → return .build

fastPathSignals (case-insensitive substring match):
  "hi", "hello", "hey", "thanks", "thank you", "ok", "okay",
  "what is", "how do i", "how does", "does this", "do we have",
  "do you have", "is there", "are there", "can you tell",
  "which port", "where is", "what port", "show me the",
  "what version", "how many", "who is"

reviewPathSignals (case-insensitive substring match):
  "review", "audit", "critique", "assess", "evaluate",
  "explain", "describe", "summarize", "summarise", "analyze",
  "analyse", "check if", "check whether", "look at",
  "look over", "walk through", "walkthrough", "inspect"

mutationSignals (case-insensitive substring match):
  "create", "write", "build", "add ", "implement", "refactor",
  "migrate", "fix ", "change ", "modify", "delete", "remove",
  "rename", "generate", "install", "set up", "configure",
  "deploy", "make a", "write a", "add a"
```

### Edge cases

| Input | Classification | Reason |
|---|---|---|
| "hi" | fast | Greeting |
| "what port is the backend on" | fast | Factual Q |
| "review career-register plugin" | review | Review signal, no mutation |
| "review the auth module and fix the timeout bug" | build | Both review AND mutation → stricter path |
| "create a contact form" | build | Mutation signal |
| "explain how hooks work" | review | Explain signal, no mutation |
| "explain how hooks work and create a demo plugin" | build | Both explain AND create → stricter |
| "refactor the database layer" | build | Mutation signal |
| "check if the plugin is ready for production" | review | Check-if signal, no explicit mutation |

---

## 4. Component Specifications

Every node conforms to `OrchestrationNode`:

```swift
protocol OrchestrationNode {
    var id: String { get }
    func run(state: OrchestrationState) async throws -> OrchestrationState
}
```

The returned state's `transition.nextNodeId` determines routing. `nil` means the graph runner exits.

### Shared dependencies (injected at construction, not passed through state)

All nodes receive these via constructor injection:

```swift
struct NodeContext {
    let aiCoordinator: AIInteractionCoordinator     // send LLM messages
    let toolExecutor: AIToolExecutor                // execute tool calls
    let historyCoordinator: ChatHistoryCoordinator  // read/write messages
    let planStore: ConversationPlanStore            // read/write TaskPlans
    let projectRoot: URL                            // project root path
    let pathValidator: PathValidator                // path resolution
    let promptRepo: PromptRepository                // load prompt templates
}
```

---

### 4.1 FastPathNode

**File:** `compass/Services/Orchestration/Nodes/FastPathNode.swift` (new, ~40 lines)

```
───────────────────────────────────────────────────────────
FastPathNode
───────────────────────────────────────────────────────────
Purpose:     Respond to greetings, factual questions, single-turn queries.
             No tools. No planning. One LLM call.

State in:    OrchestrationState
               .userInput: "hi" | "what port..." | "do we have tests?"
               .messages: [ChatMessage] (conversation history)

State out:   OrchestrationState
               .lastResponse: AIServiceResponse (assistant's reply)
               .transition.nextNodeId: FinalResponseNode.id

Tools:       None

Max LLM calls: 1 (single response, no tool loop)

Prompt:      "You are a helpful coding assistant. The user said: {userInput}.
             Respond naturally. Do NOT call tools. Do NOT explore the
             project. Just answer or make conversation."

Termination: Always routes to FinalResponseNode after 1 call.

Error:       If LLM call fails, route to FinalResponseNode with
             state.error = "Failed to respond: {error}".
───────────────────────────────────────────────────────────
```

---

### 4.2 ResearcherNode

**File:** `compass/Services/Orchestration/Nodes/ResearcherNode.swift` (new, ~80 lines)

```
───────────────────────────────────────────────────────────
ResearcherNode
───────────────────────────────────────────────────────────
Purpose:     Gather all relevant context (files, search results, directory
             listings) needed to answer the user's question or execute the
             build task. Used by both Review and Build paths.

State in:    OrchestrationState
               .userInput: original user request
               .messages: [ChatMessage] (conversation history)
               .visitCount: Int (how many times visited)

State out:   OrchestrationState
               .lastResponse: AIServiceResponse
               .collectedContext: CollectedContext (accumulated across visits)
               .transition.nextNodeId: self (continue) | nextNode (done)

Tools:       read, search, ls, glob  (no write, edit, bash)

Max visits:  5 (Review path) | 8 (Build path)
             Configurable via constructor parameter `maxVisits: Int`

Per-visit flow:
  1. If visitCount == 0: set up initial prompt with user's request.
     If visitCount > 0: inject "continue gathering context" prompt with
     current collectedContext summary.
  2. Send LLM message with tool definitions.
  3. If response has toolCalls: execute them via AIToolExecutor.
     Append tool results to history.
  4. Update collectedContext with new files read, search results, etc.
  5. If response has no toolCalls: route to nextNode (done).
  6. If visitCount >= maxVisits: route to nextNode (timeout).
  7. Otherwise: increment visitCount, route to self (continue).

CollectedContext fields:
  - readPaths: [String]           // file paths read via `read`
  - searchResults: [SearchEntry]  // results from `search`
  - listedDirectories: [String]   // dirs listed via `ls`
  - globMatches: [String]         // files found via `glob`

Prompt (visit 0):
  "You need to understand: {userInput}
   Explore the project to gather all relevant context.
   Use search to find relevant code, read to inspect files,
   ls to discover structure, glob to find files by name.
   When you have enough context, respond without tool calls
   and the next phase will begin."

Prompt (visit N > 0):
  "Continue gathering context. So far you have:
   - read {collectedContext.readPaths.count} files
   - {collectedContext.searchResults.count} search results
   If you have enough to proceed, respond without tool calls.
   Otherwise explore further."

Termination: visitCount >= maxVisits OR response.toolCalls.isEmpty.
             If timeout: append "Continue with available context." to state.
───────────────────────────────────────────────────────────
```

---

### 4.3 AnalystNode

**File:** `compass/Services/Orchestration/Nodes/AnalystNode.swift` (new, ~60 lines)

```
───────────────────────────────────────────────────────────
AnalystNode
───────────────────────────────────────────────────────────
Purpose:     Synthesize gathered context into a review, audit, critique,
             assessment, or explanation. Used by Review path only.

State in:    OrchestrationState
               .collectedContext: CollectedContext (from Researcher)
               .userInput: original review/audit/explain request
               .messages: [ChatMessage] (conversation history)

State out:   OrchestrationState
               .lastResponse: AIServiceResponse (the review/analysis)
               .transition.nextNodeId: FinalResponseNode.id

Tools:       context (vector store — check prior sessions if needed)

Max LLM calls: 3

Prompt:      "Based on the research phase, you have gathered:
             {summary of collectedContext}

             The user asked you to: {userInput}

             Produce a thorough {review|audit|critique|assessment|explanation}.
             Structure your response:
             1. Summary of what you examined
             2. Key findings with file:line references
             3. Assessment / verdict
             4. Recommendations (if applicable)

             Do NOT call tools. Deliver your analysis as your
             final assistant message. This is the analysis phase only."

Termination: response.toolCalls.isEmpty → FinalResponseNode.
             If LLM calls tools: execute them (context lookup only),
             append results, try again (max 3 visits).
             If max visits reached: emit partial analysis with note.

Edge case: collectedContext is empty (Researcher found nothing):
  Prompt adds: "No relevant context was found in the project.
  State this clearly in your response."
───────────────────────────────────────────────────────────
```

---

### 4.4 ArchitectNode

**File:** `compass/Services/Orchestration/Nodes/ArchitectNode.swift` (new, ~60 lines)

```
───────────────────────────────────────────────────────────
ArchitectNode
───────────────────────────────────────────────────────────
Purpose:     Design the solution strategy. Decide which files to create
             or modify, in what order, with what approach. Used by
             Build path only.

State in:    OrchestrationState
               .collectedContext: CollectedContext (from Researcher)
               .userInput: original build request

State out:   OrchestrationState
               .lastResponse: AIServiceResponse (architecture plan)
               .transition.nextNodeId: ProjectManagerNode.id

Tools:       read, search, context (no write, edit, bash — design only)

Max LLM calls: 3

Prompt:      "Based on the gathered context, design the solution.

             Context gathered:
             {summary of collectedContext}

             User request: {userInput}

             Produce an architecture plan covering:
             1. Which files need creating (with paths)
             2. Which files need modifying (with paths)
             3. The order of work (foundational first)
             4. Key design decisions and trade-offs
             5. Risks or prerequisites

             Do NOT call write/edit tools — this is the design phase.
             Output your architecture as your assistant message.
             Be specific: name exact files, not 'the plugin file'."

Termination: response.toolCalls.isEmpty → ProjectManagerNode.
             On timeout (3 visits): emit partial plan and proceed.
───────────────────────────────────────────────────────────
```

---

### 4.5 ProjectManagerNode

**File:** `compass/Services/Orchestration/Nodes/ProjectManagerNode.swift` (new, ~80 lines)

```
───────────────────────────────────────────────────────────
ProjectManagerNode
───────────────────────────────────────────────────────────
Purpose:     Two-phase node:
             Visit 1: Break architecture plan into PlanItems (leafs).
                      Create TaskPlan, persist via ConversationPlanStore.
             Visit 2: Assembly review — check all leafs completed and
                      the full deliverable matches the user's request.

State in:    OrchestrationState
               .taskPlan: TaskPlan? (nil on visit 1, populated on visit 2)
               .leafResults: [LeafResult] (from leaf execution, visit 2 only)
               .leafVerdicts: [LeafReviewVerdict] (from leaf QA, visit 2 only)
               .userInput: original build request
               .lastResponse: AIServiceResponse (from prior node)
               .visitCount: Int (0 = planning, 1+ = assembly)

State out:   OrchestrationState
               .taskPlan: TaskPlan (persisted, with PlanItems)
               .currentPlanItemIndex: Int (starting leaf index, 0)
               .transition.nextNodeId:
                 LeafExecutorNode.id (visit 1, start first leaf)
                 LeafExecutorNode.id (visit 2, corrections needed)
                 FinalResponseNode.id (visit 2, all done)

Tools:       read, plan, context

Max visits:  3 per phase

───────────────────────────────────────────────────────────
Visit 1 — Break Down (Planning)
───────────────────────────────────────────────────────────

This is the first visit. Occurs after ArchitectNode completes.

Prompt:      "Break this architecture into discrete, independently
             executable tasks. Each task must have:
             - description: WHAT to do (one sentence)
             - purpose: WHY (one sentence)
             - context: exact file paths involved
             - doneCriteria: HOW to verify it's complete

             Architecture to break down:
             {architect's response}

             User's original request: {userInput}

             Output the task list by calling the `plan` tool:
             plan(action: 'init', goal: '...') then
             plan(action: 'finishTask', summary: '<task summary>')
             for each task.

             Order: foundational tasks first (create file, set up structure),
             then feature tasks (add functionality),
             then polish tasks (styling, validation, tests).

             Do NOT call write/edit tools. This is planning only."

Post-call:
  Read TaskPlan from ConversationPlanStore.
  Set state.taskPlan = loadedPlan.
  Set state.currentPlanItemIndex = 0.
  Route to LeafExecutorNode.id.

───────────────────────────────────────────────────────────
Visit 2 — Assembly Review
───────────────────────────────────────────────────────────

This is the second visit. Occurs after ALL leaf reviews complete.

State .leafResults and .leafVerdicts are populated from all leaf executions.

Deterministic check:
  1. If any leafVerdict == .fail → find the FIRST failed leaf.
     Re-route to LeafExecutorNode with that leaf's index.
     Inject correction context into state.leafCorrectionContext.
  2. If all leaves passed AND TaskPlan.isComplete:
     LLM review of full deliverable.

Prompt:      "All tasks are complete. Leaf results:
             {summary of leafResults and leafVerdicts}

             User's original request: {userInput}

             Review the full deliverable:
             1. Are all requested artefacts present and correct?
             2. Do they work together?
             3. Are there gaps or inconsistencies?

             If complete, respond 'DELIVERY COMPLETE' with a summary
             of what was built for the user.
             If incomplete, respond 'DELIVERY INCOMPLETE: {reason}'
             and specify which tasks need correction."

Routing:
  - "DELIVERY COMPLETE" in response → FinalResponseNode.id
  - "DELIVERY INCOMPLETE: ..." → LeafExecutorNode.id with corrections
  - No clear signal → re-read response, try again (up to 3 visits)
───────────────────────────────────────────────────────────
```

---

### 4.6 LeafExecutorNode

**File:** `compass/Services/Orchestration/Nodes/LeafExecutorNode.swift` (new, ~80 lines)

```
───────────────────────────────────────────────────────────
LeafExecutorNode
───────────────────────────────────────────────────────────
Purpose:     Execute ONE PlanItem from the TaskPlan. This is the leaf
             that performs the actual file work (read + write + edit + verify).
             The model sees only this ONE task — no context pollution.

State in:    OrchestrationState
               .taskPlan: TaskPlan (mandatory)
               .currentPlanItemIndex: Int (which leaf to execute)
               .leafCorrectionContext: String? (if re-running a failed leaf)
               .messages: [ChatMessage] (conversation history — includes
                 plan setup from PM, previous leaf results)

State out:   OrchestrationState
               .leafResults: [LeafResult] (appended with this leaf's result)
               .currentPlanItemIndex: Int (same leaf if re-running,
                 incremented if passed)
               .transition.nextNodeId: LeafReviewNode.id

Tools:       ALL (read, write, edit, ls, glob, search, bash, plan, context)

Max visits:  8 per leaf (the leaf gets up to 8 LLM calls to complete its task)

Per-visit flow:
  1. Build focused prompt with the current PlanItem.
     If leafCorrectionContext is set, prepend: "Previous attempt failed: {reason}"
  2. Send LLM message with ALL tools.
  3. If response has toolCalls: execute them via AIToolExecutor.
     Append tool results to history.
     Increment visitCount.
  4. If response has no toolCalls AND visitCount > 0:
     Check if PlanTool(finishTask) was called.
     If yes: mark leaf done, route to LeafReviewNode.
     If no: append "Mark this task complete via plan(finishTask)."
     Try again (up to 8 visits).
  5. If visitCount >= maxVisits: mark leaf as incomplete,
     route to LeafReviewNode (which will catch it).

Prompt (first visit):
  "TASK {N}/{total}: {description}

   Purpose: {purpose}
   Files involved: {context joined by ', '}
   Verification: {doneCriteria}

   Execute this task now. Use tools to:
   - Read existing files before editing
   - Create or modify files as needed
   - Run bash to verify (tests, builds, lint)
   When done, call: plan(action: 'finishTask', summary: '...')

   Do NOT work on any other task. This leaf is your SOLE
   responsibility. Do NOT plan, architect, or review."

Prompt (visit N > 0, no correction):
  "Continue working on task {N}/{total}: {description}.
   Call plan(action: 'finishTask') when done."

Prompt (visit N > 0, with correction context):
  "Previous attempt failed: {leafCorrectionContext}
   Re-attempt task {N}/{total}: {description}.
   Fix the identified issues."

LeafResult:
  - planItemId: String
  - planItemDescription: String
  - toolCallsMade: Int
  - filesModified: [String]
  - filesCreated: [String]
  - verificationOutput: String (from bash test/build output)
  - planFinishTaskCalled: Bool
  - planFinishTaskSummary: String?
  - iterationsUsed: Int

Termination: Always routes to LeafReviewNode after completion or timeout.
───────────────────────────────────────────────────────────
```

---

### 4.7 LeafReviewNode

**File:** `compass/Services/Orchestration/Nodes/LeafReviewNode.swift` (new, ~50 lines)

```
───────────────────────────────────────────────────────────
LeafReviewNode
───────────────────────────────────────────────────────────
Purpose:     QA the leaf's output. Verify the work matches the PlanItem's
             doneCriteria. Does NOT modify files. Can trigger re-execution.

State in:    OrchestrationState
               .taskPlan: TaskPlan
               .currentPlanItemIndex: Int
               .leafResults: [LeafResult] (latest entry is this leaf)
               .messages: [ChatMessage]

State out:   OrchestrationState
               .leafVerdicts: [LeafReviewVerdict] (appended)
               .transition.nextNodeId:
                 LeafExecutorNode.id (if FAIL — re-execute same leaf)
                 PMNode.id or LeafExecutorNode.id (if PASS — next leaf or PM)

Tools:       read, search, ls (no write, edit, bash — QA only)

Max visits:  2

Per-visit flow:
  1. Read the latest LeafResult.
  2. Build prompt asking the model to verify the leaf's work.
  3. Send LLM message with read/search/ls tools.
  4. The model reads changed file(s), checks against doneCriteria.
  5. If model responds with LEAF_PASS or LEAF_FAIL signal:
     Extract verdict, route accordingly.

Prompt:      "Review task {N}/{total}: {description}

             Done criteria: {doneCriteria}
             Files involved: {context}
             Tools used: {toolCallsMade}
             Files modified: {filesModified}
             Files created: {filesCreated}
             Verification output: {verificationOutput}

             Read the modified/created files. Check them against the
             done criteria above.

             If the task is correctly completed, respond:
             'LEAF_PASS'

             If incorrect or incomplete, respond:
             'LEAF_FAIL: {specific reason and what to fix}'"

Post-call processing:
  1. Check response.content for "LEAF_PASS" or "LEAF_FAIL:".
  2. If LEAF_PASS:
     - Mark PlanItem.status = .completed in TaskPlan
     - Persist TaskPlan
     - Append LeafReviewVerdict(.pass)
     - If more leaves remain:
       - Increment currentPlanItemIndex
       - Route to LeafExecutorNode (next leaf)
     - If all leaves done:
       - Route to ProjectManagerNode (assembly review, visit 2)
  3. If LEAF_FAIL:
     - Set PlanItem.status = .active (re-open)
     - Append LeafReviewVerdict(.fail(reason))
     - Set state.leafCorrectionContext = reason
     - Route to LeafExecutorNode (re-execute same leaf)
  4. If no clear signal after 2 visits:
     - Treat as LEAF_PASS with note "automatic — QA inconclusive"
     - Route accordingly

LeafReviewVerdict:
  enum LeafReviewVerdict {
    case pass
    case fail(reason: String)
  }

Termination: Routes based on verdict (see above).
───────────────────────────────────────────────────────────
```

---

### 4.8 FinalResponseNode

**File:** `compass/Services/Orchestration/Nodes/FinalResponseNode.swift` (modified, simplified from current)

```
───────────────────────────────────────────────────────────
FinalResponseNode
───────────────────────────────────────────────────────────
Purpose:     Terminate the graph. Extract the assistant's last message
             and commit it as the final response. No LLM calls.

State in:    OrchestrationState
               .lastResponse: AIServiceResponse (from the last processing node)
               .taskPlan: TaskPlan? (for build path — used in summary)

State out:   OrchestrationState
               .transition.nextNodeId: nil (graph runner exits)

Processing:  1. Extract assistant content from lastResponse.
             2. If build path and taskPlan exists:
                Append a brief status line:
                "✓ Completed {completed}/{total} tasks."
             3. Set state.finalContent = assistantContent.
             4. Return state with transition.nextNodeId = nil.

No LLM calls. No tool execution. Pure extraction.
───────────────────────────────────────────────────────────
```

---

## 5. Graph Topologies

### 5.1 Fast Graph

```
Classifier(.fast)
  → FastPathNode
  → FinalResponseNode
```

3 nodes. 1 LLM call. Tools: none.

### 5.2 Review Graph

```
Classifier(.review)
  → ResearcherNode(maxVisits=5, next=AnalystNode)
  → AnalystNode
  → FinalResponseNode
```

3 nodes + classifier. ~8 LLM calls max. Tools: read, search, ls, glob, context.

### 5.3 Build Graph

```
Classifier(.build)
  → ResearcherNode(maxVisits=8, next=ArchitectNode)
  → ArchitectNode(next=PMNode)
  → ProjectManagerNode(next=LeafExecutorNode)  ← visit 1 (planning)
  → [LeafExecutorNode ↔ LeafReviewNode] × N    ← per PlanItem
  → ProjectManagerNode(next=FinalResponse)     ← visit 2 (assembly)
  → FinalResponseNode
```

5 node types + dynamic leaf loop + classifier. The leaf loop is controlled by the LeafReviewNode — it routes to LeafExecutor (next leaf) or PMNode (all done) or LeafExecutor (re-run).

**The leaf loop is NOT a while-loop in code.** It's the graph runner cycling through nodes. LeafReviewNode sets `state.transition.nextNodeId` to either `LeafExecutor.id` or `PMNode.id`. The graph runner follows the transition. No internal counters except `state.currentPlanItemIndex`.

### Graph factory

**File:** `compass/Services/CloudPipeline/PathGraphBuilders.swift` (new, ~100 lines)

```swift
enum PathGraphBuilders {
    static func fastGraph(context: NodeContext) -> OrchestrationGraph
    static func reviewGraph(context: NodeContext) -> OrchestrationGraph
    static func buildGraph(context: NodeContext) -> OrchestrationGraph
}
```

Each builds an `OrchestrationGraph` with the nodes wired to the topology above. The `OrchestrationGraphRunner` is reused — no changes needed.

---

## 6. Data Structures

### 6.1 Existing (reuse as-is)

All in `compass/Services/Planning/TaskPlan.swift`:

```swift
struct TaskPlan: Codable, Sendable {
    let id: String
    var goal: String
    var value: String
    var domain: PlanDomain
    var mode: AIMode
    var items: [PlanItem]
    var currentIndex: Int
    var createdAt: Date
    var completedAt: Date?
    var progress: Double { /* computed from items */ }
    var isComplete: Bool { items.allSatisfy { $0.status == .completed } }
}

struct PlanItem: Codable, Identifiable, Sendable {
    let id: String
    var description: String
    var purpose: String
    var context: [String]          // file paths, URLs
    var doneCriteria: String
    var status: ItemStatus
    var summary: String?           // model's sign-off text
    var blockedReason: String?
}

enum ItemStatus: String, Codable, Sendable {
    case pending, active, completed, blocked
}

enum PlanDomain: String, Codable, Sendable {
    case architecture, implementation, research, refactor, analysis, design, investigation
}
```

### 6.2 Existing orchestration state

From `compass/Services/Orchestration/Graph/OrchestrationState.swift` (modified):

```swift
struct OrchestrationState: Sendable {
    // Input
    var userInput: String
    var messages: [ChatMessage]

    // Current turn
    var lastResponse: AIServiceResponse?
    var lastToolCalls: [AIToolCall]
    var lastToolResults: [ChatMessage]

    // Graph control
    var transition: OrchestrationTransition
    var mode: AIMode
    var runId: String
    var conversationId: String

    // NEW: Task execution (for build path)
    var taskPlan: TaskPlan?
    var currentPlanItemIndex: Int
    var leafResults: [LeafResult]
    var leafVerdicts: [LeafReviewVerdict]
    var leafCorrectionContext: String?

    // NEW: Context collection (for review + build paths)
    var collectedContext: CollectedContext

    // NEW: Path classification
    var classification: RequestComplexity

    // Error handling
    var error: String?
}
```

### 6.3 New structures

```swift
// ~15 lines — compass/Services/CloudPipeline/RequestClassifier.swift
enum RequestComplexity: String, Sendable {
    case fast, review, build
}

// ~25 lines — compass/Services/Orchestration/CollectedContext.swift (new)
struct CollectedContext: Sendable {
    var readPaths: [String] = []
    var searchResults: [SearchEntry] = []
    var listedDirectories: [String] = []
    var globMatches: [String] = []

    var isEmpty: Bool {
        readPaths.isEmpty && searchResults.isEmpty &&
        listedDirectories.isEmpty && globMatches.isEmpty
    }

    func summary() -> String {
        // "Read 3 files, found 12 search results, listed 2 directories"
    }
}

// ~20 lines — compass/Services/Orchestration/LeafResult.swift (new)
struct LeafResult: Sendable {
    let planItemId: String
    let description: String
    var toolCallsMade: Int = 0
    var filesModified: [String] = []
    var filesCreated: [String] = []
    var verificationOutput: String = ""
    var planFinishTaskCalled: Bool = false
    var planFinishTaskSummary: String?
    var iterationsUsed: Int = 0
}

// ~10 lines — compass/Services/Orchestration/LeafReviewVerdict.swift (new)
enum LeafReviewVerdict: Sendable {
    case pass
    case fail(reason: String)
}
```

---

## 7. Walkthroughs

### 7.1 Walkthrough: "hi"

```
1. ConversationSendCoordinator.send("hi")
2. RequestClassifier.classify("hi") → .fast
3. PathGraphBuilders.fastGraph(context) → graph with FastPathNode + FinalResponseNode
4. OrchestrationGraphRunner.run(graph, initialState)

   Visit 1 — FastPathNode:
     state.userInput = "hi"
     build prompt: "You are a helpful coding assistant. The user said: hi. ..."
     → LLM call with NO tools
     → response.content = "Hi! How can I help you today?"
     state.lastResponse = response
     state.transition.nextNodeId = "final_response"

   Visit 2 — FinalResponseNode:
     state.finalContent = "Hi! How can I help you today?"
     state.transition.nextNodeId = nil
     graph runner exits

5. ConversationSendCoordinator extracts finalContent
6. Commits to history, displays to user

Total LLM calls: 1. Total tool calls: 0. Total time: ~2s.
```

### 7.2 Walkthrough: "review career-register plugin"

```
1. Classifier.classify("review career-register plugin") → .review
   (review signal present, no mutation signal)
2. PathGraphBuilders.reviewGraph(context)

   Visit 1 — ResearcherNode (visit 0):
     Prompt: "You need to understand: review career-register plugin"
     LLM call with tools: search, ls, glob, read
     → model calls: ls wp-content/plugins/career-register/
     → result: shows 5 files
     → model calls: read career-register.php (read 1)
     → model calls: read class-career-register.php (read 2)
     → model calls: read assets/... (read 3-5)
     model responds without tool calls: "I've read all 5 files..."

   Visit 2 — ResearcherNode (visit 1):
     collectedContext has 5 readPaths, 1 ls result
     LLM: no more tool calls needed → routes to AnalystNode

   Visit 3 — AnalystNode:
     Prompt: "Based on the research phase... produce a thorough review..."
     LLM call with tools: context only
     → model produces review:
       "# Career Register Plugin Review
        ## Architecture: ...  ## Security: ...  ## Verdict: NOT production-ready ..."
     no tool calls → routes to FinalResponseNode

   Visit 4 — FinalResponseNode:
     state.finalContent = review text

Total LLM calls: 3-5. Total tool calls: ~8. Total time: ~15s.
```

### 7.3 Walkthrough: "create a contact form WordPress plugin"

```
1. Classifier.classify("create a contact form WordPress plugin") → .build
   ("create" is a mutation signal)

2. PathGraphBuilders.buildGraph(context)

   Phase: Research
   Visit 1 — ResearcherNode:
     Gather context: existing plugin structure, WordPress hooks reference,
     existing form patterns in the codebase
     ~5 LLM calls, ~10 tool calls → routes to ArchitectNode

   Phase: Architecture
   Visit 6 — ArchitectNode:
     Design: plugin entry file, shortcode class, form template, CSS,
     activation hook, uninstall hook
     2 LLM calls → routes to ProjectManagerNode

   Phase: Planning
   Visit 8 — ProjectManagerNode (visit 1):
     Break down into 6 PlanItems via plan tool:
      1. Create plugin entry file (career-contact.php)
      2. Create ContactForm shortcode class
      3. Add form template (HTML/CSS)
      4. Add form handler (POST processing, validation)
      5. Add admin settings page
      6. Add activation/uninstall hooks
     TaskPlan persisted. 6 items, all pending.
     Routes to LeafExecutorNode for item 1.

   Phase: Execute (repeats for each PlanItem)

   Item 1: "Create plugin entry file"
     Visit 9 — LeafExecutorNode:
       read WordPress plugin header conventions
       write wp-content/plugins/career-contact/career-contact.php
       → plan(action: finishTask, summary: "Created plugin entry file")
       route to LeafReviewNode

     Visit 10 — LeafReviewNode:
       read career-contact.php
       Check: "Plugin header exists, text domain declared, no syntax errors"
       LEAF_PASS → mark item 1 complete → route to LeafExecutor for item 2

   Item 2: "Create ContactForm shortcode class"
     Visit 11 — LeafExecutorNode:
       edit career-contact.php to add class definition
       → plan(action: finishTask)
       route to LeafReviewNode

     Visit 12 — LeafReviewNode:
       read, verify
       LEAF_FAIL: "Missing nonce verification in form handler"
       Route to LeafExecutorNode (re-execute item 2 with correction)

     Visit 13 — LeafExecutorNode (re-run item 2):
       Correction: "Previous attempt failed: Missing nonce verification"
       edit career-contact.php, add wp_nonce_field
       → plan(action: finishTask)
       route to LeafReviewNode

     Visit 14 — LeafReviewNode:
       LEAF_PASS

   ... items 3-6 execute similarly with QA ...

   Phase: Assembly
   Visit ~30 — ProjectManagerNode (visit 2):
     All 6 leafs passed. Assembly review:
     LLM reads all files, checks against original request.
     "DELIVERY COMPLETE: Created career-contact plugin with shortcode,
      form handler, validation, admin settings, and activation hooks.
      All 6 tasks completed successfully."
     Routes to FinalResponseNode

   Visit 31 — FinalResponseNode:
     state.finalContent = delivery summary

Total LLM calls: ~30. Total tool calls: ~50-70. Total time: ~3-5 min.
All controlled by the graph runner. No infinite loops. No stall detection.
Every leaf QA'd before proceeding. PM verifies full deliverable at end.
```

---

## 8. Implementation Plan

### Phase 1: Deletion (Day 1)

**Goal:** Remove all dead/harmful code. Get a clean build.

**Actions:**
1. Delete all files listed in §9 Cleanup.
2. Fix compilation errors from removed types:
   - `ConversationSendCoordinator`: remove references to `ToolLoopHandler`, `ToolLoopNode`, etc.
   - `ConversationManager`: remove references to deleted services.
   - `DependencyContainer`: remove instantiation of deleted services.
   - `compassApp.swift`: remove deleted imports.
3. Update `AIToolExecutor` to not depend on deleted services (`ToolTimeoutCenter`, `ToolExecutionCoordinator`, `ToolScheduler`, etc.). The executor now receives tool calls and returns results directly — no coordination layer.
4. Build → fix → build → `./run.sh build` passes with exit 0.

**Deliverable:** Buildable codebase with no ToolLoopHandler or related services. App launches but agent doesn't function yet (no graph nodes).

---

### Phase 2: Core Infrastructure (Day 2-3)

**Goal:** Create the node framework, classifier, and fast path. Get basic agent working.

**Actions:**
1. Create `RequestClassifier.swift` — classify user input.
2. Create `CollectedContext.swift` — data structure.
3. Create `LeafResult.swift` — data structure.
4. Create `LeafReviewVerdict.swift` — data structure.
5. Create `NodeContext` struct in a shared location (`Orchestration/NodeContext.swift`).
6. Create `PathGraphBuilders.swift` — three graph factory functions.
7. Create `FastPathNode.swift` — simple response node.
8. Simplify `FinalResponseNode.swift` — remove FinalResponseHandler call, just extract last content.
9. Update `ConversationSendCoordinator.send()` to:
   ```
   classify → build graph → run graph → extract final content
   ```
10. Update `DependencyContainer` to create `NodeContext` and pass it to `ConversationSendCoordinator`.
11. Build → test "hi" → responds in 1 turn.

**Deliverable:** Agent responds to "hi" with a greeting. No tools. 1 LLM call. ~0 tool calls.

---

### Phase 3: Review Path (Day 4-5)

**Goal:** Review/audit/critique prompts work correctly.

**Actions:**
1. Create `ResearcherNode.swift` — gather context via search/read/ls/glob.
2. Create `AnalystNode.swift` — synthesise analysis from gathered context.
3. Add review-path graph to `PathGraphBuilders.reviewGraph()`.
4. Wire classifier → `.review` routes to review graph.
5. Build → test "review career-register plugin" → researches 5 files → delivers review in ~6 turns.
6. Verify: no loops, no bash calls during research (only search/read/ls/glob).

**Deliverable:** Agent reviews WordPress plugins. ~4-6 LLM calls. ~8 tool calls. Produces actual review text.

---

### Phase 4: Build Path — Planning (Day 6-7)

**Goal:** Build tasks get planned and broken down. Architecture design works.

**Actions:**
1. Update `ResearcherNode` to accept `maxVisits: 8` for build path.
2. Create `ArchitectNode.swift` — design solution, produce file map.
3. Create `ProjectManagerNode.swift` — visit 1 (break down) + visit 2 (assembly review).
4. Add build-path graph to `PathGraphBuilders.buildGraph()`.
5. Update `OrchestrationState` to include new fields (`taskPlan`, `leafResults`, `collectedContext`, etc.).
6. Wire classifier → `.build` routes to build graph.
7. Build → test "create a contact form WordPress plugin" → researcher gathers context → architect designs → PM breaks into PlanItems → plan persisted.
8. Verify: TaskPlan has 4-8 PlanItems. Each has description, purpose, context (files), doneCriteria.

**Deliverable:** Build tasks reach PM planning phase. TaskPlan is created and persisted. Leaf execution not yet implemented.

---

### Phase 5: Build Path — Leaf Execution + QA (Day 8-10)

**Goal:** Leaves execute, get QA'd, re-execute on fail. Full pipeline works.

**Actions:**
1. Create `LeafExecutorNode.swift` — execute one PlanItem with all tools.
2. Create `LeafReviewNode.swift` — QA leaf output, route based on pass/fail.
3. Wire the leaf loop in build graph:
   - PM → LeafExecutor (first leaf)
   - LeafExecutor → LeafReview (always)
   - LeafReview(PASS) → LeafExecutor (next leaf) or PMNode (all done)
   - LeafReview(FAIL) → LeafExecutor (same leaf with correction context)
4. Update `ConversationPlanStore` to support `markItemComplete(planId, itemIndex)` and `markItemActive(planId, itemIndex)`.
5. Build → test "create a simple plugin" end-to-end.
6. Verify: leaf executes, QA checks, on fail re-executes with correction. On pass moves to next leaf. PM assembly review validates full deliverable.

**Deliverable:** Full build pipeline works end-to-end. Leaf QA catches errors. PM assembly review validates complete deliverable.

---

### Phase 6: Integration Test + Polish (Day 11-12)

**Goal:** End-to-end testing. Edge cases. Polish.

**Actions:**
1. Test fast path: "hi", "what port", "do we have tests", "how does X work", "where is Y" — all respond in 1 turn.
2. Test review path: "review X", "audit Y", "explain Z", "assess W", "critique V" — all gather context and deliver analysis.
3. Test build path: "create X", "refactor Y", "add Z to W", "fix V", "implement U" — all proceed through full pipeline.
4. Test edge cases:
   - Empty input: fast path, respond with error message.
   - Very long input: still classify correctly (use first sentence).
   - Mixed intent: "review X and create Y" → build path (stricter).
   - No tools needed: fast path, 1 LLM call.
   - Task that requires 0 files: PM creates PlanItem with empty context.
   - All leafs fail: PM assembly review catches this, reports to user.
5. Run `./run.sh build` after each change.
6. Update AGENTS.md with new architecture documentation.

**Deliverable:** Production-ready agentic system. Process scaling works. No infinite loops. No stall detection. Clean architecture.

---

## 9. Cleanup: Delete List

### Core — ToolLoopHandler ecosystem

| File | Lines | Why |
|---|---|---|
| `Services/CloudPipeline/ToolLoopHandler.swift` | 2961 | Replaced by graph nodes. The while-loop-inside-graph is the root cause. |
| `Services/CloudPipeline/ToolLoopConstants.swift` | 105 | Constants for deleted ToolLoopHandler. |
| `Services/CloudPipeline/ToolLoopUtilities.swift` | 531 | Recovery prompt builders — all recovery is now graph routing. |
| `Services/CloudPipeline/StallDetector.swift` | 126 | Stall detection — replaced by per-node visit limits + PlanCompletenessStrategy. |
| `Services/CloudPipeline/FollowUpMessageAssembler.swift` | ~150 | Recovery prompt injection. |
| `Services/CloudPipeline/LoopBreakController.swift` | ~80 | Loop break logic. |
| `Services/CloudPipeline/PipelineProcessor.swift` | ~100 | Pipeline preprocessing. |
| `Services/CloudPipeline/ConversationSendModels.swift` | ~50 | Model definitions for ToolLoopHandler. |
| `Services/CloudPipeline/MessageTruncationPolicy.swift` | ~120 | Truncation for recovery prompts. |
| `Services/CloudPipeline/ToolResultProcessor.swift` | ~100 | Tool result processing for loop. |
| `Services/CloudPipeline/InitialResponseHandler.swift` | ~50 | Wraps single LLM call — inlined into nodes. |
| `Services/CloudPipeline/FinalResponseHandler.swift` | ~600 | Final response handling — replaced by FinalResponseNode + PlanCompletenessStrategy. |
| `Services/CloudPipeline/QAReviewHandler.swift` | ~200 | QA review — replaced by LeafReviewNode. |
| `Services/CloudPipeline/ResearchSubagent.swift` | ~120 | Sub-agent spawning — never shipped. |
| `Services/CloudPipeline/ResearchTool.swift` | ~200 | Research tool — never delivered value. |

### Graph — dead or replaced nodes

| File | Lines | Why |
|---|---|---|
| `Services/Orchestration/Nodes/ToolLoopNode.swift` | 82 | Wraps ToolLoopHandler — deleted with it. |
| `Services/Orchestration/Nodes/DispatcherNode.swift` | ~80 | Replaced by per-path dispatchers (FastPathNode, ResearcherNode). |
| `Services/Orchestration/Nodes/EmptyResponseRecoveryNode.swift` | ~60 | Patch for empty dispatcher responses — no longer needed. |
| `Services/Orchestration/Nodes/BranchReviewNode.swift` | ~80 | Deprecated branch review — replaced by LeafReviewNode. |
| `Services/Orchestration/Nodes/BranchExecutionContinuationDecider.swift` | ~100 | Deprecated — marked @available(*, deprecated). |
| `Services/Orchestration/Nodes/OrchestrationExecutorNode.swift` | 55 | Dead code from makeStateMachineGraph. |
| `Services/Orchestration/Nodes/OrchestrationPlannerNode.swift` | 40 | Dead code — planner never wired. |
| `Services/Orchestration/ConversationFlowGraphFactory.swift` | 104 | Replaced by PathGraphBuilders. |

### Tooling — loop-specific infrastructure

| File | Lines | Why |
|---|---|---|
| `Services/ToolExecutionCoordinator.swift` | ~200 | Coordinator wrapping AIToolExecutor — executor now called directly. |
| `Services/ToolExecutionLogger.swift` | ~150 | Heavy logging wrapper. |
| `Services/AIToolTraceLogger.swift` | ~200 | Trace logging for ToolLoopHandler. |
| `Services/ToolExecutionTelemetry.swift` | ~100 | Telemetry for ToolLoopHandler. |
| `Services/ToolWatchdog.swift` | ~80 | Watchdog for ToolLoopHandler. |
| `Services/ToolTimeoutCenter.swift` | ~250 | Timeout management for ToolLoopHandler. |
| `Services/ToolCallOrderingSanitizer.swift` | ~60 | Tool call ordering. |
| `Services/ToolCallFallbackParser.swift` | ~200 | Fallback parsing. |
| `Services/ToolArgumentResolver.swift` | ~100 | Argument resolution. |
| `Services/ToolScheduler.swift` | ~100 | Scheduling. |
| `Services/ToolAliasRegistry.swift` | 60 | Legacy name aliasing — prompts now use canonical names. |
| `Services/AIToolProgressReporting.swift` | ~30 | Progress reporting protocol. |
| `Services/Tools/ToolTimeoutCircuitBreaker.swift` | ~200 | Circuit breaker. |
| `Services/Tools/ToolFileAccessLedger.swift` | 48 | File access tracking — enforcement moved to FileToolWriteApplier. |

### Tools — removed from list

| File | Lines | Why |
|---|---|---|
| `Services/Tools/PinnedRuleAddTool.swift` | ~30 | Never demonstrated value. |
| `Services/Tools/PinnedRuleRemoveTool.swift` | ~30 | Same. |
| `Services/Tools/PinnedRuleListTool.swift` | ~30 | Same. |
| `Services/Tools/GoogleWebSearchTool.swift` | ~100 | External API dependency. Rarely used for coding tasks. |
| `Services/Tools/WebBrowseTool.swift` | ~200 | Same. |
| `Services/Tools/FileToolProposalStager.swift` | ~100 | Propose-mode staging — never used productively. |

### Already deleted from working tree

| Directory | Files | Why |
|---|---|---|
| `Services/Conversation/` | 8 files, ~600 lines | State storage — replaced by SessionManager. Remove from git tracking. |

**Total deleted: ~9,000 lines. ~40 files removed.**

---

## 10. Keep List (do not delete)

### Tools (core — all working)

| File | Notes |
|---|---|
| `Services/Tools/ReadFileTool.swift` | Core file reading with line/char range |
| `Services/Tools/WriteFileTool.swift` | Core file writing with read-before-write enforcement |
| `Services/Tools/PatchFileToolAdapter.swift` | Core file editing with old_string/new_string mode |
| `Services/Tools/DeleteFileTool.swift` | Core file deletion |
| `Services/Tools/ListFilesTool.swift` | Core directory listing |
| `Services/Tools/FindFileTool.swift` | Core file search with path optional |
| `Services/Tools/SearchProjectTool.swift` | Core code search (symbol + FTS + grep) |
| `Services/Tools/TerminalTools.swift` | Core bash execution with exploration blocker |
| `Services/Tools/ContextTool.swift` | Core context recall from vector store |
| `Services/Tools/ToolTaxonomy.swift` | Core read-only vs mutation classification |
| `Services/Tools/FileToolWriteApplier.swift` | File write application |

### Planning (all working)

| File | Notes |
|---|---|
| `Services/Planning/TaskPlan.swift` | TaskPlan, PlanItem, ItemStatus, PlanDomain |
| `Services/Planning/PlanTool.swift` | AITool for planning |
| `Services/ConversationPlanStore.swift` | Actor-backed plan persistence |

### Execution

| File | Notes |
|---|---|
| `Services/AIToolExecutor.swift` | Tool dispatch |
| `Services/AIToolExecutor+Execution.swift` | Tool execution engine |
| `Services/AIToolExecutor+Batch.swift` | Batch tool execution |
| `Services/AIToolExecutor+Logging.swift` | Execution logging |

### Core infrastructure

| File | Notes |
|---|---|
| `Services/ConversationToolProvider.swift` | Tool assembly (trim to 9 tools) |
| `Services/ChatHistoryCoordinator.swift` | Message history |
| `Services/ConversationManager.swift` | Send/receive orchestration |
| `Services/ConversationSendCoordinator.swift` | Graph dispatch (rewritten) |
| `Services/SessionManager.swift` | Session persistence |
| `Services/AIInteractionCoordinator.swift` | LLM call dispatch |
| `Services/PathValidator.swift` | Path resolution |
| `Services/FileSystemService.swift` | File I/O |
| `Services/EventBus.swift` | Event pub/sub |

### Prompting

| File | Notes |
|---|---|
| `Services/SystemPromptAssembler.swift` | Prompt assembly (simplified — no loop-specific injections) |
| `Services/CloudPipeline/ProjectShapeSummary.swift` | Project orientation |
| `Services/CloudPipeline/RequestClassifier.swift` | New — request complexity |
| `Services/CloudPipeline/PathGraphBuilders.swift` | New — graph factories |
| `Prompts/System/*.md` | System prompts |
| `Prompts/Tools/v3/*.md` | Tool docs |

### Graph framework

| File | Notes |
|---|---|
| `Services/Orchestration/Graph/OrchestrationGraph.swift` | Graph definition |
| `Services/Orchestration/Graph/OrchestrationGraphRunner.swift` | Graph runner |
| `Services/Orchestration/Graph/OrchestrationState.swift` | Graph state (modified) |
| `Services/Orchestration/ExecutionResult.swift` | Executor output |
| `Services/Orchestration/ReviewDecision.swift` | Reviewer routing |
| `Services/Orchestration/Strategies/ReviewStrategy.swift` | Review protocol |
| `Services/Orchestration/Strategies/PlanCompletenessStrategy.swift` | Deterministic completion check |

### Index

| File | Notes |
|---|---|
| `Services/Index/IndexFrameworkDetection.swift` | Framework detection |
| `Services/Index/IndexExcludePatternManager.swift` | Index exclude management |

---

## 11. Testing Strategy

### Unit tests (can run offline)

**RequestClassifier:**
- "hi" → .fast
- "what port is the backend on" → .fast
- "review career-register plugin" → .review
- "create a contact form" → .build
- "review the auth module and fix the timeout bug" → .build
- "explain hooks and create a demo" → .build
- "" → .fast

**PlaningCompletenessStrategy:**
- Empty plan → .complete (nothing to do)
- All items completed → .complete
- Some pending → .continue
- One blocked → .continue (with blocked item context)

**CollectedContext.summary():**
- Empty → "No context gathered"
- 3 read, 5 search, 2 ls → "Read 3 files, found 5 search results, listed 2 directories"

### Integration tests (WordPress project)

**Fast path:**
- "hi" → responds in 1 turn, no tools called
- "what port is the backend on" → responds with answer, 0-1 tools (context)

**Review path:**
- "review career-register plugin" → 4-8 turns, 5-15 tool calls, review delivered
- No bash calls, no write/edit calls
- `ls` tool returns expected directory contents (verify ls is not broken)

**Build path (online — requires LLM):**
- "create a simple hello-world plugin" → full pipeline, ~15-30 turns
- PlanItems created, leafs executed, QA passed, PM assembly complete
- All created files exist on disk

### Regression tests (existing)

- `IndexAndToolsTests` — edit old_string/new_string, framework detection — must still pass
- `WriteFileToolTests` — write/create/overwrite — must still pass

---

## Appendix A: Current State vs Target State

| Metric | Current (broken) | Target (this spec) |
|---|---|---|
| Architecture | Graph wrapping while-loop | Pure graph with process scaling |
| LLM calls for "hi" | 3-5 (force-execution followup loop) | 1 |
| LLM calls for "review X" | 50+ (infinite loop until killed) | 4-8 |
| LLM calls for "build Y" | 100+ (or killed at 262k tokens) | 20-40 |
| Tool calls for "review X" | 64 (mostly redundant ls/search) | 8-15 |
| Stall detection conditions | 22 | 0 |
| Recovery mechanisms | 6 (prompt injection) | 0 (structural routing) |
| Lines of code (agent pipeline) | ~9,600 | ~1,200 |
| Dead code | ~3,000 lines | 0 |
| Tool list | 15 | 9 |
| Function-calling overhead per turn | ~7.5k tokens | ~4.5k tokens |
| Deterministic completion | Never wired | PlanCompletenessStrategy always active on build path |
| Built-in QA per task | None | Every leaf reviewed before proceeding |
| Process scaling | None — same loop for everything | 3 paths by complexity |

## Appendix B: Migration Path from Current State

1. **Don't delete anything yet.** Build new files alongside old ones.
2. **Phase 1:** Create all new data structures and node files. They compile alongside old code — no conflicts.
3. **Phase 2:** Create PathGraphBuilders with all three graphs. Wire into ConversationSendCoordinator via a feature flag (`USE_NEW_ARCHITECTURE`).
4. **Phase 3:** Test all three paths via the feature flag. Old path still works in parallel.
5. **Phase 4:** Flip the flag to default-on. If regression, flip back.
6. **Phase 5:** Delete all old files. Remove feature flag.

This is a **parallel build, then cut over** strategy — zero downtime, full rollback capability.
