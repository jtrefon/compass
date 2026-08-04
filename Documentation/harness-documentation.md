# Harness Documentation — Closed-Loop Feedback for the Coding Agent

**Status**: Proposal
**Purpose**: Document the harness as a closed-loop feedback mechanism that eliminates the human from the loop between the coding agent and the software under test.

---

## 1. Core Purpose

The harness exists to close the loop between the coding agent and the software it's building.

**Before** (human in the loop):
1. Agent makes changes to the codebase
2. Human manually builds the project
3. Human runs the app, clicks around, observes behavior
4. Human describes what happened back to the agent (copy-paste, screenshots, manual notes)
5. Agent iterates based on that description

**After** (closed loop):
1. Agent makes changes to the codebase
2. Harness orchestrates the real app with those changes
3. Telemetry flows back immediately (structured, machine-readable)
4. Agent reads telemetry and iterates

The harness **never implements anything**. It only:
- **Orchestrates** — runs the real application code paths, not mocks
- **Observes** — captures telemetry from the running system
- **Reports** — provides structured, machine-readable feedback

This means when the agent applies a change, the harness immediately reflects that change — no disconnect between what the agent coded and what the harness tests.

---

## 2. Architecture

### 2.1 The Loop

```
┌─────────────────────────────────────────────────────┐
│                 CODING AGENT                        │
│                                                     │
│  1. Reads telemetry from previous iteration         │
│  2. Decides what to change                          │
│  3. Applies changes to codebase                      │
│  4. Sends prompt to harness                         │
└─────────────┬───────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────┐
│                 HARNESS                              │
│                                                     │
│  1. Boots real DependencyContainer (production path) │
│  2. Injects prompt via ConversationManager           │
│  3. Runs full pipeline:                             │
│     - Intent classification                         │
│     - Tool loop (read/write/execute)                 │
│     - Final response                                │
│     - QA review (if enabled)                        │
│  4. Captures telemetry:                             │
│     - Orchestration snapshots (JSONL)                │
│     - Tool execution trails                         │
│     - Conversation history                          │
│     - Performance metrics                           │
│  5. Reports structured results                       │
└─────────────┬───────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────┐
│              TELEMETRY FEEDBACK                      │
│                                                     │
│  - Pass/fail assertions                             │
│  - Tool call patterns                               │
│  - File system state                                │
│  - Conversation transcript                          │
│  - Performance numbers                              │
└─────────────────────────────────────────────────────┘
```

### 2.2 Production Parity

The harness uses the **real** `DependencyContainer`, the **real** `ConversationManager`, and the **real** `ConversationSendCoordinator`. It does not mock the AI service, the tool executor, or the file system — unless a test explicitly needs to script behavior (e.g., `ScriptedAIService` for stall detection tests).

This is the critical invariant: **what the agent sees in the harness is what the user sees in the app**. If the agent fixes a bug in the tool loop, the harness immediately reflects that fix.

### 2.3 Two Paths

| Path | When | How | Iteration Budget |
|------|------|-----|------------------|
| **Cloud** | Uses OpenRouter/Kilo Code | OrchestrationGraphRunner (LangGraph-inspired) | Up to 50 iterations (agent) / 10 (coder) |
| **Local** | Uses MLX local model | `executeLocalModelToolLoop()` | Up to 8 iterations |

---

## 3. Telemetry Schema

The harness emits structured telemetry that the agent can read to understand what happened. This is the feedback channel.

### 3.1 Orchestration Snapshots

**Location**: `.ide/orchestration/runs/{conversationId}/{runId}.jsonl`

One JSON line per graph transition. Schema:

```json
{
  "runId": "uuid",
  "conversationId": "uuid",
  "phase": "dispatcher" | "tool_loop" | "empty_response_recovery" | "branch_review" | "final_response" | "qa_tool_output_review" | "qa_quality_review",
  "iteration": 1,
  "timestamp": "2025-01-01T00:00:00Z",
  "userInput": "User's original message",
  "assistantDraft": "Last assistant content (truncated)",
  "failureReason": "null or reason",
  "executionSignals": {
    "deliveryState": "done" | "needsWork" | "missing",
    "hasToolCalls": true,
    "hasToolResults": true,
    "hasIncompletePlan": false,
    "shouldForceExecutionFollowup": false,
    "shouldForceToolFollowup": false,
    "missingClaimedArtifacts": false
  },
  "toolCalls": [
    {
      "id": "call-1",
      "name": "write_file",
      "argumentKeys": ["content", "path"]
    }
  ],
  "toolResults": [
    {
      "toolCallId": "call-1",
      "toolName": "write_file",
      "status": "completed" | "failed",
      "targetFile": "/path/to/file.txt",
      "outputPreview": "Truncated output..."
    }
  ]
}
```

**How to read**: Each line is one node transition. The sequence of `phase` values shows the graph's path. `toolCalls` and `toolResults` show what tools were called and their outcomes.

### 3.2 Inference Performance Metrics

**Location**: `InferencePerformanceMetrics` struct (memory, CSV export available)

```swift
InferencePerformanceMetrics {
  testId: String
  modelId: String
  configurationLabel: String
  contextLength: Int
  maxKVSize: Int
  maxOutputTokens: Int
  prefillStepSize: Int
  conversationTurn: Int
  promptTokenCount: Int
  outputTokenCount: Int
  timeToFirstToken: TimeInterval   // TTFT — how long until first visible token
  totalDuration: TimeInterval
  peakMemoryMB: UInt64
  mlxLoadMilliseconds: Int?        // Local model only
  mlxPromptTokenCount: Int?
  mlxPromptMilliseconds: Int?
  mlxPromptTokensPerSecond: Double?
  mlxGenerationTokenCount: Int?
  mlxGenerationMilliseconds: Int?
  mlxGenerationTokensPerSecond: Double?
  rssBeforeLoadMB: Int?
  rssAfterLoadMB: Int?
  rssAfterGenerationMB: Int?
  timestamp: Date
}
```

**Key fields for agent feedback**:
- `timeToFirstToken` — responsiveness of the system
- `peakMemoryMB` — memory pressure
- `mlxGenerationTokensPerSecond` — local model throughput
- `outputTokenCount` — how much the model produced

### 3.3 Tool Execution Telemetry

**Location**: `ToolExecutionTelemetry.shared` (in-memory singleton)

Tracks:
- Repeated tool calls (same name + arguments)
- Deduplicated tool calls (cache hits)
- Successful vs. failed executions
- Iteration counts

### 3.4 Conversation History

**Location**: `.ide/logs/conversations/{conversationId}/conversation.ndjson`

Structured log of every message in the conversation, with role, content, tool calls, and timestamps.

---

## 4. Running the Harness

### 4.1 Commands

```bash
# All offline harness suites (no external API calls)
./run.sh harness

# Single suite
./run.sh harness ToolLoopEngineRecoveryHarnessTests

# Online harness (hits real AI providers — requires API keys)
COMPASS_RUN_ONLINE_HARNESS=1 ./run.sh harness AgenticHarnessTests

# Convenience wrappers
./run.sh harness-online              # All online suites
./run.sh harness-offline             # All offline suites
./run.sh harness-online AgenticHarnessTests  # Single online suite
```

### 4.2 Memory Guard

The harness wraps all runs in a memory guard that kills the process if RSS exceeds the limit:
- **Default**: 6 GB
- **Override**: `HARNESS_MAX_RSS_GB=8` (e.g., for larger local models)

### 4.3 Environment Variables

| Variable | Effect | Default |
|---------|--------|--------|
| `COMPASS_RUN_ONLINE_HARNESS=1` | Enables online harness (hits real AI providers) | Disabled |
| `HARNESS_MAX_RSS_GB` | Memory guard limit (kills if exceeded) | 6 |
| `HARNESS_MODEL_ID` | Override the AI model used | — |
| `HARNESS_USE_OPENROUTER` | Force OpenRouter provider | — |
| `ALLOW_EXTERNAL_APIS` | Allow real API calls | true |
| `USE_MOCK_SERVICES` | Use mock AI service | false |
| `SWIFT_ENABLE_EXPLICIT_MODULES` | Swift explicit modules | false |
| `COMPASS_DISABLE_HEAVY_INIT` | Skip heavy initialization | false |

---

## 5. Writing a Harness Test

### 5.1 Pattern A: Scripted (No External APIs)

Use `ScriptedAIService` to pre-program responses. Fast, deterministic, no API keys needed.

**When to use**: Testing stall detection, tool loop recovery, malformed tool calls, read caching.

```swift
@MainActor
final class MyScriptedTests: XCTestCase {
    func testMyScenario() async throws {
        let projectRoot = makeTempDir()
        defer { cleanup(projectRoot) }

        let historyCoordinator = makeHistoryCoordinator(projectRoot: projectRoot)
        let conversationId = historyCoordinator.currentConversationId
        let runId = UUID().uuidString

        let scriptedService = ScriptedAIService(responses: [
            AIServiceResponse(content: "Starting.", toolCalls: [AIToolCall(id: "call-1", name: "write_file", arguments: ["path": "/test.txt", "content": "hello"])]),
            AIServiceResponse(content: "Done.", toolCalls: nil)
        ])

        let aiInteractionCoordinator = AIInteractionCoordinator(
            aiService: scriptedService,
            codebaseIndex: nil,
            eventBus: MockEventBus()
        )
        let toolExecutor = AIToolExecutor(
            fileSystemService: FileSystemService(),
            errorManager: HarnessErrorManager(),
            projectRoot: projectRoot
        )
        let toolExecutionCoordinator = ToolExecutionCoordinator(toolExecutor: toolExecutor)
        let handler = ToolLoopHandler(
            historyCoordinator: historyCoordinator,
            aiInteractionCoordinator: aiInteractionCoordinator,
            toolExecutionCoordinator: toolExecutionCoordinator
        )

        let result = try await handler.handleToolLoopIfNeeded(
            response: AIServiceResponse(content: "Starting.", toolCalls: [firstToolCall]),
            mode: .agent,
            projectRoot: projectRoot,
            conversationId: conversationId,
            availableTools: [FakeTool(name: "fake_tool")],
            cancelledToolCallIds: { [] },
            runId: runId,
            userInput: "Do something"
        )

        harnessTrue(result.response.toolCalls?.isEmpty ?? true, "Should finish without dangling tool calls")
    }
}
```

### 5.2 Pattern B: Production-Parity Online (Real AI Service)

Uses the real `DependencyContainer` and real AI provider (OpenRouter/Kilo Code). Tests the full pipeline.

**When to use**: Validating end-to-end behavior — file creation, multi-file scaffolding, real tool execution.

```swift
@MainActor
final class MyOnlineTests: XCTestCase {
    private func requireOnlineHarnessExecution() throws {}

    override func setUp() async throws {
        try await super.setUp()
        await OnlineHarnessExecutionGate.shared.acquire()  // Prevents 429 floods
        let config = TestConfiguration(
            allowExternalAPIs: true,
            minAPIRequestInterval: 1.0,
            serialExternalAPITests: true,
            externalAPITimeout: 180.0,
            useMockServices: false
        )
        await TestConfigurationProvider.shared.setConfiguration(config)
    }

    override func tearDown() async throws {
        await TestConfigurationProvider.shared.resetToDefault()
        await OnlineHarnessExecutionGate.shared.release()
        try await super.tearDown()
    }

    func testMyOnlineScenario() async throws {
        try requireOnlineHarnessExecution()

        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let runtime = try await makeProductionRuntime(projectRoot: projectRoot)
        let manager = runtime.manager
        manager.currentMode = .coder

        try await sendProductionMessage("Create a file called hello.txt", manager: manager, timeoutSeconds: 300)

        let files = listAllFiles(under: projectRoot)
        harnessTrue(files.contains("hello.txt"), "File should have been created")

        assertNoRawToolMarkupInFinalAssistantMessage(manager)
    }
}
```

### 5.3 Pattern C: Offline MLX (Local Model)

Tests with the local MLX model. No external API calls.

**When to use**: Testing local model behavior, offline mode, local tool subset.

```swift
func testOfflineScenario() async throws {
    let projectRoot = makeTempDir(prefix: "offline_test")
    let runtime = try await makeRuntime(offlineModeEnabled: true, projectRoot: projectRoot)
    let manager = runtime.manager
    manager.currentMode = .agent

    manager.currentInput = "Read source.txt and create result.txt"
    manager.sendMessage()

    let timedOut = try await waitForConversationToFinish(manager, timeoutSeconds: 60)
    XCTAssertFalse(timedOut, "Offline run should finish")
}
```

### 5.4 Pattern D: Graph Runner (Unit-Level)

Tests the `OrchestrationGraphRunner` directly with passthrough nodes. No AI service needed.

**When to use**: Testing graph mechanics — snapshot writing, max transitions, phase ordering.

```swift
func testGraphRunner() async throws {
    let projectRoot = makeTempDir()
    defer { cleanup(projectRoot) }

    let graph = OrchestrationGraph(
        entryNodeId: "a",
        nodes: [
            PassthroughNode(id: "a", nextId: "b"),
            PassthroughNode(id: "b", nextId: nil)
        ]
    )

    let runner = OrchestrationGraphRunner(graph: graph, maxTransitions: 10)
    let request = makeSendRequest(conversationId: UUID().uuidString, runId: UUID().uuidString, projectRoot: projectRoot)
    _ = try await runner.run(initialState: OrchestrationState(
        request: request,
        transition: .next("a")
    ))
}
```

---

## 6. Shared Utilities

### 6.1 File System

| Function | Purpose |
|----------|--------|
| `makeTempDir()` | Creates a temporary directory (unique prefix) |
| `makeTempDir(prefix:)` | Creates a temp dir with a named prefix |
| `cleanup(projectRoot)` | Removes the temp directory |
| `listAllFiles(under:)` | Returns sorted list of file paths relative to the directory |

### 6.2 Runtime

| Function | Purpose |
|----------|--------|
| `makeProductionRuntime(projectRoot:)` | Boots real `DependencyContainer` with real services |
| `makeRuntime(offlineModeEnabled:)` | Boots runtime with local MLX model |
| `makeHistoryCoordinator(projectRoot:)` | Creates a fresh `ChatHistoryCoordinator` |

### 6.3 Communication

| Function | Purpose |
|----------|--------|
| `sendProductionMessage(text, manager:)` | Sends a message and waits for completion |
| `waitForConversationToFinish(manager:)` | Polls until `manager.isSending` becomes false |
| `assertNoRawToolMarkupInFinalAssistantMessage(manager)` | Validates no `<tool_code>` or `&#x1F517;` leaked into final message |

### 6.4 Assertions

| Function | Purpose |
|----------|--------|
| `harnessTrue(condition, label:)` | Asserts condition is true, with label |
| `harnessFalse(condition, label:)` | Asserts condition is false, with label |
| `harnessEqual(lhs, rhs, label:)` | Asserts equality, with label |
| `harnessNote(text)` | Prints a non-failing diagnostic note |
| `harnessLog(text)` | Prints structured log entry |

### 6.5 Test Doubles

| Type | Purpose |
|------|--------|
| `ScriptedAIService` | Returns pre-programmed responses from a FIFO queue |
| `MockEventBus` | No-op event bus for isolation |
| `HarnessErrorManager` | Captures errors for inspection |
| `PassthroughNode` | Graph node that does nothing, just transitions |

---

## 7. Online Gate

### 7.1 What It Is

`OnlineHarnessExecutionGate.shared` is an actor that serializes access to online tests. Only one online test runs at a time.

**Why**: Parallel provider traffic causes 429 rate-limit floods and can get the account banned.

### 7.2 How It Works

```swift
// In setUp:
await OnlineHarnessExecutionGate.shared.acquire()  // Blocks if another test holds the gate

// In tearDown:
await OnlineHarnessExecutionGate.shared.release()   // Unblocks the next waiter
```

### 7.3 When to Use

Any test that hits an external AI provider (OpenRouter, Kilo Code) must use the gate. Tests that only use `ScriptedAIService` or local MLX do not.

### 7.4 Environment Variable

Online tests are skipped unless `COMPASS_RUN_ONLINE_HARNESS=1` is set. This prevents accidental API usage in CI or local development.

---

## 8. Test File Index

| File | Pattern | What It Validates |
|------|---------|-------------------|
| `AgenticHarnessTests.swift` | B (online) | Full production-parity: file creation, multi-file scaffolding, React apps, tool execution |
| `ToolLoopEngineRecoveryHarnessTests.swift` | A (scripted) | Stall detection, read cache, malformed tool calls, empty finalization recovery |
| `ToolLoopDropoutHarnessTests.swift` | A (scripted) | Ball-drop prevention, plan completion, continuation guards |
| `ToolLoopContinuationGuardHarnessTests.swift` | A (scripted) | Recovery summary, execution recovery |
| `OfflineModeHarnessTests.swift` | C (local MLX) | Offline agent mode, local tool subset, multi-step local flow |
| `OrchestrationSnapshotHarnessTests.swift` | D (graph) | Graph runner mechanics, snapshot writing, max transitions, phase ordering |
| `NetworkRetryHarnessTests.swift` | A (scripted) | Network retry, flaky service, banner clearing |
| `LocalModelResponseDiagnosticsHarnessTests.swift` | C (local MLX) | Response diagnostics, reasoning extraction, visible output validation |
| `FullToolChainHarnessTest.swift` | B (online) | End-to-end: read_file, write_file, patch_file, web_search, search_project, multi-tool cycle |
| `RealServiceToolLoopTests.swift` | B (online) | Tool loop with real OpenRouter, tool deduplication, error handling |
| `EdgeCaseScenariosTests.swift` | B (online) | Empty project, large files, malformed files, memory pressure |
| `InferencePerformanceMetrics.swift` | Utility | Performance metrics collection, CSV export |
| `TelemetryValidationTests.swift` | B (online) | Telemetry quality, completeness, accuracy |
| `IndexScopeHarnessTests.swift` | A (scripted) | Index scope isolation, database path verification |
| `WebSearchHarnessTests.swift` | B (online) | Web search tool validation |
| `StreamingPerformanceHarnessTests.swift` | C (local MLX) | Streaming performance, TTFT |
| `SSEStreamTimeoutHarnessTests.swift` | A (scripted) | SSE stream timeout handling |
| `LocalModelRefactoringHarnessTests.swift` | C (local MLX) | Local model refactoring scenarios |
| `RAGPreventionHarnessTests.swift` | B (online) | RAG prevention, context isolation |
| `EmbeddingBenchmarkHarnessTests.swift` | C (local MLX) | Embedding model benchmarking |
| `ToolVacuumHarnessTests.swift` | A (scripted) | Tool vacuum lifecycle, batch processing |
| `FrozenContextChainHarnessTests.swift` | A (scripted) | Frozen context chain isolation |
| `OnlineHarnessExecutionGate.swift` | Infrastructure | Gate implementation (not a test file) |

---

## 9. Debugging

### 9.1 Reading Orchestration Snapshots

```bash
# Find the run
ls .ide/orchestration/runs/<conversationId>/

# Read the JSONL
cat .ide/orchestration/runs/<conversationId>/<runId>.jsonl

# Each line is a node transition:
# Line 1: phase="dispatcher", iteration=1
# Line 2: phase="tool_loop", iteration=2
# Line 3: phase="final_response", iteration=3
```

### 9.2 Reading Conversation Logs

```bash
# Find the conversation log
ls .ide/logs/conversations/<conversationId>/

# Read the NDJSON
cat .ide/logs/conversations/<conversationId>/conversation.ndjson
```

### 9.3 Common Failure Modes

| Symptom | Likely Cause | Where to Look |
|---------|-------------|---------------|
| Agent drops out before finishing | Plan incomplete, `BranchReviewNode` routed to finalization | `executionSignals.hasIncompletePlan` in snapshots |
| Agent reads same file repeatedly | Read cache working? Check for `read_cache_hit` events | Trace logs |
| Agent stalls on write | Post-write non-mutation stall detected | `postWriteNonMutationStallThreshold` in `ToolLoopConstants` |
| Final answer is empty | `FinalResponseHandler` — was `deliveryState == .done`? | Snapshots, trace for `empty_finalization_fallback` |
| Run takes too long | Wall-clock timeout (600s) hit | Trace for `max_duration_reached` |
| 429 errors | Online tests running in parallel | `OnlineHarnessExecutionGate` — was `acquire()` called? |

### 9.4 Stall Detection Reference

The engine detects stalls and intervenes before the iteration budget is exhausted:

| Strategy | Threshold | Triggers When |
|----------|-----------|---------------|
| Repeated batch stall | 4 identical batches | Same tool batch repeated |
| Repeated completed signature | 5 rounds | Same completed tool calls repeated |
| Read-only iteration stall | 10 consecutive | Only read tools, no writes |
| Read-only batch stall | 3 identical read batches | Same read pattern repeated |
| Post-write non-mutation | 3 iterations | After a write, only reads follow |
| Repeated write target | 4 iterations | Same file written repeatedly |
| Convergence stall | 15 reads since last mutation | Reading without converging |
| Wall-clock timeout | 600s | Hard stop |
| Empty response stall | 3 consecutive | Empty responses in a row |

Recovery actions (in order):
1. **Nudge** — inject corrective system message ("stop reading, start writing")
2. **Diversify tools** — force mutation-only tool subset
3. **Force finalization** — request summary from LLM
4. **Recursive re-entry** — re-enter tool loop (max 3 deep)

---

## 10. Anti-Patterns

### 10.1 Harness Implements Logic

**Wrong**: The harness duplicates business logic to "simulate" what the app does.

**Right**: The harness runs the real app code. Changes in the app are immediately reflected.

```swift
// WRONG — harness implements its own tool logic
func testWriteFile() {
    let result = myOwnWriteFileImplementation("hello.txt", "content")
    XCTAssertEqual(result, "ok")
}

// RIGHT — harness runs the real path
func testWriteFile() {
    try await sendProductionMessage("Create hello.txt", manager: manager)
    XCTAssertTrue(files.contains("hello.txt"))
}
```

### 10.2 Running Online Tests in Parallel

**Wrong**: Multiple online tests run simultaneously, causing 429 floods.

**Right**: Use `OnlineHarnessExecutionGate` to serialize.

```swift
// WRONG — no gate
override func setUp() async throws {
    // no acquire/release
}

// RIGHT — serialized
override func setUp() async throws {
    await OnlineHarnessExecutionGate.shared.acquire()
}
override func tearDown() async throws {
    await OnlineHarnessExecutionGate.shared.release()
}
```

### 10.3 Mocking the Production Path

**Wrong**: Using mocks for the AI service in production-parity tests.

**Right**: Use real services for production-parity tests. Use `ScriptedAIService` only for focused unit tests.

### 10.4 Hardcoding Model IDs

**Wrong**: Tests that only work with a specific model.

**Right**: Use `HARNESS_MODEL_ID` environment variable to override.

---

## 11. Glossary

| Term | Meaning |
|------|---------|
| **Closed loop** | The feedback cycle: agent changes code → harness runs real app → telemetry → agent iterates |
| **Production parity** | The harness runs the same code path as the real app, with the same `DependencyContainer` |
| **Orchestration graph** | Directed graph of nodes (dispatcher → tool loop → recovery → review → final) that routes the conversation through stages |
| **Snapshot** | NDJSON line written per graph transition for post-mortem analysis |
| **Scripted service** | Test double that returns pre-programmed responses from a FIFO queue (for unit-level tests only) |
| **Tool loop** | Closed-loop iteration: LLM produces tool calls → tools execute → results fed back → LLM produces more calls or final answer |
| **Stall** | The engine detects the LLM is not making progress and intervenes |
| **Ball drop** | The LLM stops producing tool calls before the task is complete — the engine forces a continuation |
| **TTFT** | Time To First Token — how long until the first visible output |

---

## 12. What This Document Doesn't Cover

- **Detailed agentic architecture** — see [`agentic-architecture.md`](../Documentation/agentic-architecture.md)
- **Harness testing improvements history** — see [`harness-testing-improvements.md`](../Documentation/harness-testing-improvements.md)
- **Design rationale for stall thresholds** — see code comments and `ToolLoopConstants.swift`
- **How to write a new `AITool`** — separate concern
