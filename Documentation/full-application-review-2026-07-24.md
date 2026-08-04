# Full Application Review — 2026-07-24

## Executive summary

The current working tree is **not production-ready**. Its active conversation/orchestration rewrite has replaced a mature tool loop, scheduler, telemetry, timeout handling, and substantial test coverage with incomplete graph nodes and compatibility stubs. The primary Coder path can either fail to perform requested work or repeatedly invoke the model until the graph transition limit is reached. Tool execution now bypasses the production executor and its safety/reliability controls.

This review examined the current filesystem state, not only committed code. That distinction is critical: `git diff --stat` shows 23,199 deleted lines across 148 files, including the prior tool loop and many unit/harness tests, while replacement architecture files are currently untracked. Findings below therefore describe the application as it would be built from this working tree.

## Review scope and method

- Reviewed 524 production Swift files (55,690 lines) and the active production paths from `DependencyContainer` → `ConversationManager` → `ConversationSendCoordinator` → orchestration graph/tool execution.
- Inspected the current graph, request classifier, tool-execution replacement, context mechanism, startup path, EventBus, build/test scripts, test inventory, and UI-token compliance samples.
- Used the repository's cardinal rules: one production path, harness must orchestrate rather than duplicate, dead code must be identified, and build output is the source of truth.
- A clean `./run.sh build` was attempted. It did **not** compile because package resolution could not resolve `github.com` in this environment. It therefore cannot validate or invalidate the static findings below. The build script also deletes `.build/` before resolving dependencies, so there was no usable cached dependency graph to fall back to.

## Findings

### P0 — Coder/build orchestration has an unconditional cycle and cannot complete normally

**Evidence.** `ProjectManagerNode` routes to `leaf_executor` whenever `state.visitCount == 0`, otherwise to `final_response` ([ResearcherNode.swift:98](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:98)). However, no active node increments `visitCount`; the sole state increment helper is unused. `LeafReviewNode` then routes success back to `pm` ([ResearcherNode.swift:149](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:149)). The runner only terminates after a node returns no next ID and otherwise throws at 64 transitions ([OrchestrationGraphRunner.swift:25](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationGraphRunner.swift:25), [OrchestrationGraphRunner.swift:47](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationGraphRunner.swift:47)).

**Impact.** A normal mutation request continually cycles `pm → leaf_executor → leaf_review → pm`, incurs unnecessary provider calls, and ultimately fails with an orchestration-limit error instead of completing the user task.

**Recommendation.** Stop shipping the graph until each route has explicit, tested completion conditions. Make progression state part of a single immutable transition API, increment it in the runner (not ad-hoc nodes), and add deterministic tests for every edge and terminal state.

### P0 — The new tool coordinator bypasses the production executor and removes safety, scheduling, cancellation, telemetry, and output contracts

**Evidence.** The new `ToolExecutionCoordinator` loops through tools and directly calls `tool.execute` ([ToolExecutionSupport.swift:100](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:100)–[ToolExecutionSupport.swift:127](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:127)). It accepts an `AIToolExecutor` but never uses it. The coordinator is invoked by both graph execution and the local model path ([ConversationSendCoordinator.swift:204](/Users/jack/Projects/osx/compass/compass/Services/ConversationSendCoordinator.swift:204)).

The replacement also defines no-op scheduler, trace logger, timeout center, ordering sanitizer, and timeout circuit breaker ([ToolExecutionSupport.swift:8](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:8)–[ToolExecutionSupport.swift:97](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:97), [ToolExecutionSupport.swift:130](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:130)–[ToolExecutionSupport.swift:136](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:136)). Tool result messages are raw strings rather than the established execution envelopes ([ToolExecutionSupport.swift:113](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:113)–[ToolExecutionSupport.swift:122](/Users/jack/Projects/osx/compass/compass/Services/ToolExecutionSupport.swift:122)).

**Impact.** Mutating tool calls can run without the path serialization, safeguards, cancellation, timeout, progress, audit trail, or model-facing tool-message semantics that the rest of the app expects. This violates the repository's “one production path—one working path” rule and is a direct reliability and security regression.

**Recommendation.** Delete the compatibility execution path. Route every graph/local-model call through one production `AIToolExecutor` API and preserve its scheduler, timeout/circuit-breaker, prevention checks, telemetry, and `ToolExecutionEnvelope` construction. Add end-to-end tests for cancellation, a timed-out tool, two writes to one path, malformed mutations, and failed tools.

### P0 — Active graph nodes are placeholders that do not implement their declared responsibilities

**Evidence.** The graph builders advertise distinct review/build paths ([PathGraphBuilders.swift:26](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/PathGraphBuilders.swift:26)–[PathGraphBuilders.swift:98](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/PathGraphBuilders.swift:98)), but:

- `ResearcherNode.maxVisits` is stored but never applied, and its `collectedContext` is never populated ([ResearcherNode.swift:12](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:12)–[ResearcherNode.swift:52](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:52)).
- `AnalystNode` and `ArchitectNode` make generic model calls with no role-specific prompt or accumulated research context ([ResearcherNode.swift:55](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:55)–[ResearcherNode.swift:96](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:96)).
- `ProjectManagerNode` neither creates a plan nor tracks plan items, despite the state schema containing these fields ([ResearcherNode.swift:98](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:98)–[ResearcherNode.swift:117](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:117), [OrchestrationState.swift:135](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:135)–[OrchestrationState.swift:162](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:162)).
- `LeafReviewNode` decides based on whether arbitrary model text contains `LEAF_FAIL` ([ResearcherNode.swift:147](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:147)–[ResearcherNode.swift:150](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ResearcherNode.swift:150)).
- `PipelineProcessor` is currently three no-op pass-through methods ([PipelineProcessor.swift:3](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/PipelineProcessor.swift:3)–[PipelineProcessor.swift:5](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/PipelineProcessor.swift:5)).

**Impact.** The apparent multi-stage architecture is not an implementation. It adds provider latency and complexity while failing to plan, constrain, evaluate, or reliably finalize work.

**Recommendation.** Either restore the previously working loop and develop the graph behind a feature flag, or complete one vertical slice before migrating: real plan generation → execute one item through the executor → deterministic review → terminal response. Do not expose unimplemented role nodes as active production paths.

### P0 — Test and harness coverage was removed during the rewrite, while `run.sh` still names deleted suites

**Evidence.** The current diff deletes most online harness suites and many targeted unit tests, including tool scheduling, graph runner, tool parsing, timeout, context, and local-model tests. The script still invokes deleted suites such as `AgenticHarnessTests`, `RealServiceToolLoopTests`, `ToolLoopDropoutHarnessTests`, `OrchestrationSnapshotHarnessTests`, and `OfflineModeHarnessTests` ([run.sh:428](/Users/jack/Projects/osx/compass/run.sh:428)–[run.sh:465](/Users/jack/Projects/osx/compass/run.sh:465)). The remaining state-machine tests exercise only the isolated `PlanCompletenessStrategy`; they do not instantiate or traverse an active graph ([PlanCompletenessStrategyTests.swift:4](/Users/jack/Projects/osx/compass/compassTests/PlanCompletenessStrategyTests.swift:4)–[PlanCompletenessStrategyTests.swift:73](/Users/jack/Projects/osx/compass/compassTests/PlanCompletenessStrategyTests.swift:73)).

**Impact.** Regression detection has been removed exactly where the rewrite is most dangerous. CI/local commands can fail due to non-existent test targets or give a false sense of coverage.

**Recommendation.** Restore the deleted tests before removing the old architecture, update `run.sh` atomically with test renames/removals, and require an offline graph integration suite that validates finalization, tool execution, cancellation, failure recovery, and no raw markup leakage.

### P1 — Request routing is brittle, semantically unsafe, and largely untested

**Evidence.** Routing is substring matching over only the first sentence ([RequestClassifier.swift:19](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/RequestClassifier.swift:19)–[RequestClassifier.swift:57](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/RequestClassifier.swift:57)). Broad substrings mean `"this"` matches `"hi"`, `"what is wrong? Then fix it"` is fast-path, and a request can be classified based on incidental words such as `"remove"` in a read-only question. There are no classifier tests in the current test tree.

**Impact.** The app selects tool availability and an orchestration topology based on accidental text matches. A mutation can be sent down the no-tool fast path; read-only work can enter the broken build path.

**Recommendation.** Make routing structured and conservative: use explicit UI mode/capability constraints first, tokenize and match words/phrases with boundaries, consider the whole request, and default uncertain requests to a safe, single path. Add a table-driven test matrix including negations, multi-sentence prompts, code snippets, and conflicting verbs.

### P1 — Mode design and comments are inconsistent with the project contract

**Evidence.** The repository contract says Chat/Coder/Agent share the same agent machinery and Coder is the primary working mode. Yet `ConversationManager` describes Coder as using a “PROVEN ToolLoopHandler” that has been deleted, and describes Chat/Agent as routed through graph architecture ([ConversationManager.swift:746](/Users/jack/Projects/osx/compass/compass/Services/ConversationManager.swift:746)–[ConversationManager.swift:789](/Users/jack/Projects/osx/compass/compass/Services/ConversationManager.swift:789)). The actual send coordinator routes every cloud request through the new graph ([ConversationSendCoordinator.swift:83](/Users/jack/Projects/osx/compass/compass/Services/ConversationSendCoordinator.swift:83)–[ConversationSendCoordinator.swift:89](/Users/jack/Projects/osx/compass/compass/Services/ConversationSendCoordinator.swift:89)).

**Impact.** Maintainers cannot reason from the mode documentation or comments, and test coverage may target a different behavior from the executable code.

**Recommendation.** Establish a single mode matrix—prompt, allowed tools, active pipeline, and support status—and enforce it in one capability policy. Remove obsolete comments at the same time as the code they describe.

### P1 — State model contains overlapping, unused concepts and weakly typed routing

**Evidence.** `OrchestrationState` retains legacy fields (`plan`, `executionResult`, `reviewDecision`, `modelChoseToStop`) alongside a second rebuild set (`taskPlan`, `currentPlanItemIndex`, `leafResults`, `leafVerdicts`, `leafCorrectionContext`, `visitCount`) ([OrchestrationState.swift:126](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:126)–[OrchestrationState.swift:164](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:164)). Transitions use untyped string IDs, and state updating has 17 optional parameters ([OrchestrationState.swift:168](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:168)–[OrchestrationState.swift:211](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Graph/OrchestrationState.swift:211)).

**Impact.** Invalid state combinations are easy to create, transitions are not compiler-checked, and inactive legacy fields conceal which implementation is authoritative.

**Recommendation.** Delete obsolete state before adding more. Replace string IDs with a closed `NodeID` enum, model each phase as a distinct state/associated value, and make transitions validate invariants at construction.

### P1 — Context integrity contract is self-contradictory and has a race-prone synchronous API

**Evidence.** `ContextStack` claims the only mutation is `push` and that it is append-only, but publicly exposes `clear()` ([ContextStack.swift:3](/Users/jack/Projects/osx/compass/compass/Core/ContextStack.swift:3)–[ContextStack.swift:29](/Users/jack/Projects/osx/compass/compass/Core/ContextStack.swift:29)). `pushSync` is nonisolated and merely queues an asynchronous task, so it does not provide synchronous ordering despite its name ([ContextStack.swift:31](/Users/jack/Projects/osx/compass/compass/Core/ContextStack.swift:31)–[ContextStack.swift:35](/Users/jack/Projects/osx/compass/compass/Core/ContextStack.swift:35)).

**Impact.** A caller can observe a context snapshot before `pushSync` has executed, and claimed immutable history can silently disappear. This is particularly dangerous for agent state, auditing, and reproducibility.

**Recommendation.** Choose and enforce one contract: append-only canonical history plus separately disposable derived context. Remove `clear` from the canonical type, remove `pushSync`, and force callers to `await` mutation completion.

### P1 — Startup blocks for up to 30 seconds while heavy services are still being initialized, then proceeds in a partially known state

**Evidence.** The dependency container launches detached initialization ([DependencyContainer.swift:147](/Users/jack/Projects/osx/compass/compass/Services/DependencyContainer.swift:147)–[DependencyContainer.swift:150](/Users/jack/Projects/osx/compass/compass/Services/DependencyContainer.swift:150)), then busy-polls main-actor state 300 times over 30 seconds ([DependencyContainer.swift:204](/Users/jack/Projects/osx/compass/compass/Services/DependencyContainer.swift:204)–[DependencyContainer.swift:220](/Users/jack/Projects/osx/compass/compass/Services/DependencyContainer.swift:220)). On timeout it logs and continues, and it follows this with more heavyweight vector-store/model work.

**Impact.** Initialization has unclear readiness semantics, higher startup latency, and race-prone partial-service availability.

**Recommendation.** Model initialization as an explicit state machine with independently awaitable service readiness. Replace polling and arbitrary timeouts with completion continuations/tasks, visible degraded capabilities, and cancellation on project changes.

### P2 — EventBus can deadlock/re-enter under a subscriber that publishes synchronously

**Evidence.** `EventBus.publish` holds `NSLock` while calling `PassthroughSubject.send` ([EventBus.swift:68](/Users/jack/Projects/osx/compass/compass/Core/EventBus.swift:68)–[EventBus.swift:73](/Users/jack/Projects/osx/compass/compass/Core/EventBus.swift:73)). The comment asserts re-entrancy safety, but `NSLock` is non-reentrant. Although current subscriptions are delivered on the main queue, a future or internally attached synchronous subscriber can publish another event and self-deadlock.

**Impact.** A central infrastructure component has fragile lock semantics that are difficult to diagnose when it fails.

**Recommendation.** Lock only to retrieve/create the subject, release before `send`, and use an actor or a carefully designed typed subject registry rather than `String(describing:)` keys plus `Any` casts.

### P2 — UI design-token standards are not enforced and currently violated broadly

**Evidence.** `DESIGN_STANDARDS.md` requires layout, spacing, radii, colors, and shared sizes to come from `AppConstants`; component source has many literal values. Examples include [AISettingsTab.swift:355](/Users/jack/Projects/osx/compass/compass/Components/AISettingsTab.swift:355) and [AISettingsTab.swift:357](/Users/jack/Projects/osx/compass/compass/Components/AISettingsTab.swift:357) (literal radius `10`), [IndexStatusBarView.swift:129](/Users/jack/Projects/osx/compass/compass/Components/IndexStatusBarView.swift:129)–[IndexStatusBarView.swift:224](/Users/jack/Projects/osx/compass/compass/Components/IndexStatusBarView.swift:224), and [AIChatPanel.swift:88](/Users/jack/Projects/osx/compass/compass/Components/AIChatPanel.swift:88)–[AIChatPanel.swift:144](/Users/jack/Projects/osx/compass/compass/Components/AIChatPanel.swift:144).

**Impact.** Visual behavior will drift and break scaling/accessibility tuning; changes require editing many views instead of a token table.

**Recommendation.** First add the missing semantic tokens to `AppConstants`, then migrate high-traffic shared components. Add SwiftLint custom rules for literal spacing/frame values in component code, with narrowly documented preview exceptions.

### P2 — Production diagnostics expose implementation and user/tool data through `print`

**Evidence.** Direct console logging is pervasive in production services. A particularly sensitive example logs local tool names and full argument dictionaries ([ConversationSendCoordinator.swift:195](/Users/jack/Projects/osx/compass/compass/Services/ConversationSendCoordinator.swift:195)–[ConversationSendCoordinator.swift:196](/Users/jack/Projects/osx/compass/compass/Services/ConversationSendCoordinator.swift:196)). Search, web, indexing, model loading, and startup paths similarly use raw `print` rather than a centralized redacting logger.

**Impact.** Paths, source fragments, credentials accidentally passed as tool arguments, and user requests may leak into console/system logs. Noise also obscures actionable operational diagnostics.

**Recommendation.** Make `AppLogger`/`DiagnosticsLogger` the only production logging path, use structured fields with redaction, gate debug diagnostics by build/configuration, and prohibit raw `print` outside previews/tests via linting.

### P2 — Large multi-responsibility files and manual asynchronous task ownership increase maintenance cost

**Evidence.** Several active files exceed 700–1,000 lines: `NativeMLXGenerator.swift` (1,039), `ChatPromptBuilder.swift` (1,022), `ConversationManager.swift` (1,014), `AIToolExecutor+Execution.swift` (957), `OpenAICompatibleChatService.swift` (801), and `DependencyContainer.swift` (744). The codebase also launches numerous unstructured `Task {}` blocks from UI and service layers; some have stored cancellation handles, many do not.

**Impact.** Responsibilities, isolation boundaries, and cancellation ownership are opaque. This makes regressions from retries, project changes, or view disappearance likely.

**Recommendation.** Split by stable responsibility (transport, stream assembly, prompt construction, model lifecycle, UI projection); make long-lived task ownership explicit; use task groups/actors or cancellable service APIs instead of fire-and-forget tasks.

## Architectural target

Before adding features, reduce to one executable vertical path:

1. `ConversationManager` creates a request from canonical history and the mode capability policy.
2. A single orchestration state machine selects either the stable legacy loop or a fully implemented graph—never both.
3. Every tool call enters `AIToolExecutor`, which owns validation, serialization, timeout, cancellation, progress, envelope construction, telemetry, and history append.
4. Canonical conversation history is append-only; model-window compaction is a derived, observable projection.
5. A finalizer commits exactly one terminal assistant message after the loop reaches an explicit terminal state.
6. Offline integration tests traverse every graph path and failure mode; online tests validate provider behavior serially.

## Additional audit — duplicates, dead code, and design-pattern use

### P1 — A second independent subagent/tool loop duplicates the primary execution concern

**Evidence.** `ResearchSubagent` creates its own history coordinator, builds a subset of tools, calls the provider in a five-turn loop, and directly executes each tool ([ResearchSubagent.swift:13](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/ResearchSubagent.swift:13)–[ResearchSubagent.swift:120](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/ResearchSubagent.swift:120)). `ResearchTool` exposes that loop inside the normal tool catalogue ([ResearchTool.swift:3](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/ResearchTool.swift:3)–[ResearchTool.swift:66](/Users/jack/Projects/osx/compass/compass/Services/CloudPipeline/ResearchTool.swift:66); [ConversationToolProvider.swift:68](/Users/jack/Projects/osx/compass/compass/Services/ConversationToolProvider.swift:68)–[ConversationToolProvider.swift:77](/Users/jack/Projects/osx/compass/compass/Services/ConversationToolProvider.swift:77)). This duplicates both the active `ConversationSendCoordinator` loop and the direct-execution `ToolExecutionCoordinator` path already identified above.

**Impact.** There are at least three places that can decide what a tool loop is, how many turns it has, how history is shaped, and how tool output is represented. The research path bypasses the production executor's safety, telemetry, cancellation, and envelope semantics in the same way as the replacement coordinator.

**Recommendation.** Make research a constrained orchestration mode/node that uses the same request preparation, `AIToolExecutor`, history model, and observability as every other execution. Do not expose an isolated loop as a tool until that integration exists.

### P1 — The new streaming parser pipeline and legacy fallback parser are competing implementations; the declared replacement is not on the production path

**Evidence.** `TextualToolCallStage` says that it replaces `ToolCallFallbackParser` ([TextualToolCallStage.swift:3](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/TextualToolCallStage.swift:3)–[TextualToolCallStage.swift:16](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/TextualToolCallStage.swift:16)), and `ToolCallFallbackParser` is marked as phase-2 legacy ([ToolCallFallbackParser.swift:3](/Users/jack/Projects/osx/compass/compass/Services/ToolCallFallbackParser.swift:3)–[ToolCallFallbackParser.swift:5](/Users/jack/Projects/osx/compass/compass/Services/ToolCallFallbackParser.swift:5)). However, the active `OpenAICompatibleChatService` still owns and injects the legacy parser ([OpenAICompatibleChatService.swift:12](/Users/jack/Projects/osx/compass/compass/Services/OpenAICompatibleChatService.swift:12), [OpenAICompatibleChatService.swift:29](/Users/jack/Projects/osx/compass/compass/Services/OpenAICompatibleChatService.swift:29)–[OpenAICompatibleChatService.swift:48](/Users/jack/Projects/osx/compass/compass/Services/OpenAICompatibleChatService.swift:48)); `OpenRouterAIService` uses it too. No production reference instantiates `EventPipeline` or `TextualToolCallStage`; their references are tests and comments.

**Impact.** Both parser systems must be maintained and can diverge in supported formats and markup stripping. The new pipeline delivers no production benefit while adding code and tests to sustain.

**Recommendation.** Select one parser pipeline. If the stage pipeline is the target, integrate it behind an explicit feature flag, run it in shadow mode against the legacy parser, compare structured outputs, then remove the legacy parser and its call sites. Otherwise delete or clearly quarantine the unused pipeline.

### P1 — Dead production code and unimplemented abstractions obscure the actual architecture

**Confirmed dead code (zero references outside the declaration file):**

- `CodePromptBuilder.swift` contains four `AIService` convenience methods, but no call site references the extension or its methods ([CodePromptBuilder.swift:3](/Users/jack/Projects/osx/compass/compass/Services/CodePromptBuilder.swift:3)–[CodePromptBuilder.swift:34](/Users/jack/Projects/osx/compass/compass/Services/CodePromptBuilder.swift:34)).
- `ContextManagementConfig` and `ContextWindowRolling` are self-contained and have no consumers ([ContextWindowRolling.swift:15](/Users/jack/Projects/osx/compass/compass/Services/ContextWindowRolling.swift:15)–[ContextWindowRolling.swift:82](/Users/jack/Projects/osx/compass/compass/Services/ContextWindowRolling.swift:82)).
- `PlannerNode` has only its declaration—there are no conformers or consumers ([PlannerNode.swift:4](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/PlannerNode.swift:4)–[PlannerNode.swift:7](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/PlannerNode.swift:7)). `ExecutorNode` and `ReviewerNode` similarly have no conformers; their only other occurrences are comments/type references ([ExecutorNode.swift:5](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ExecutorNode.swift:5)–[ExecutorNode.swift:7](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ExecutorNode.swift:7), [ReviewerNode.swift:5](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ReviewerNode.swift:5)–[ReviewerNode.swift:7](/Users/jack/Projects/osx/compass/compass/Services/Orchestration/Nodes/ReviewerNode.swift:7)).

**Impact.** These files make the codebase advertise capabilities (prompt helpers, context policy, plan/execute/review abstractions) that runtime cannot use. This violates the project rule to identify dead code rather than merely creating it, and creates false confidence during maintenance.

**Recommendation.** Delete these artifacts now if they are not scheduled for an imminent, scoped implementation. If they are intentionally future work, move them out of the app target or mark them `PHASE 2+ — NOT ON RUNTIME PATH`, with an owner and removal/activation criterion. Do not retain production-target interfaces with zero conformers.

### P2 — “Strategy/registry” abstractions are applied without ownership or concurrency guarantees

**Evidence.** `ParserRegistry` is declared `@unchecked Sendable` but holds a mutable unsynchronized dictionary and exposes concurrent mutation (`register`, `unregister`, `clear`) and reads ([ParserRegistry.swift:7](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/ParserRegistry.swift:7)–[ParserRegistry.swift:35](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/ParserRegistry.swift:35)). `TextualToolCallStage` is also `@unchecked Sendable` and shares that registry ([TextualToolCallStage.swift:10](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/TextualToolCallStage.swift:10)–[TextualToolCallStage.swift:16](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/TextualToolCallStage.swift:16)).

**Impact.** `@unchecked Sendable` suppresses compiler checking rather than making the registry safe. If the pipeline is wired concurrently, a parser registration/clear or parser-state change can race parsing. The claimed extensibility is not safe by construction.

**Recommendation.** Make parser configuration immutable after composition, or put the registry behind an actor/lock and require parser instances to have explicit per-stream state. Prefer a value-type parser configuration injected into an actor-owned pipeline.

### P2 — Dependency inversion is weakened by provider closures and runtime service lookup

**Evidence.** `ConversationToolProvider` receives closures for `AIService`, index, and project-root resolution ([ConversationToolProvider.swift:10](/Users/jack/Projects/osx/compass/compass/Services/ConversationToolProvider.swift:10)–[ConversationToolProvider.swift:29](/Users/jack/Projects/osx/compass/compass/Services/ConversationToolProvider.swift:29)); it passes those into `ResearchTool`, which resolves them at execution time. This is effectively a service locator hidden behind closures rather than explicit request-scoped dependencies.

**Impact.** A tool's behavior can change between registration and execution, dependency lifetimes are opaque, and isolated tests must recreate composition details instead of injecting a stable collaborator. It also encourages the duplicate nested-loop design.

**Recommendation.** Build an immutable `ToolExecutionContext` per conversation/run (project root, index, provider-facing orchestration interface, capabilities), inject it into tool construction, and reject execution if the context has become stale rather than silently resolving a different service.

### P2 — Pattern terminology is used as architecture rather than as a verified runtime design

**Evidence.** Several comments claim replacement or pattern properties—e.g. the parser “Strategy pattern” and open/closed extensibility ([ParserRegistry.swift:3](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/ParserRegistry.swift:3)–[ParserRegistry.swift:6](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/ParserRegistry.swift:6)), and `BufferCoordinatorStage` claims CQRS ([BufferCoordinatorStage.swift:5](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/BufferCoordinatorStage.swift:5)–[BufferCoordinatorStage.swift:17](/Users/jack/Projects/osx/compass/compass/Services/StreamingPipeline/BufferCoordinatorStage.swift:17))—but the parser pipeline is unconnected and the plan/execute/review interfaces have no implementations.

**Impact.** Names and comments conceal incomplete integration. This is architecture-shaped code rather than a functioning architecture, increasing review burden and encouraging additional parallel paths.

**Recommendation.** Treat patterns as a means, not a deliverable. Every introduced abstraction should have one production consumer, one concrete implementation when required, explicit ownership/isolation, and integration tests that exercise it on the runtime path.

## Remediation order

1. **Block release and restore a known-good Coder loop** (or disable Coder graph routing behind a feature flag).
2. **Remove tool-execution stubs** and restore the real execution path with its tests.
3. **Make the graph executable**: typed state, deterministic progress, terminal routes, no placeholder nodes, and end-to-end tests.
4. **Restore/update the deleted unit and harness suites**; make `run.sh` reference only existing suites.
5. **Add routing, mode-policy, and context-integrity tests**, then simplify duplicated state and comments.
6. **Eliminate duplicate/dead paths**: remove the standalone research loop, choose one textual tool parser, and delete/quarantine zero-consumer production code.
7. **Harden infrastructure**: readiness state machine, EventBus lock discipline, centralized redacted logging, task ownership, and actor-safe parser ownership.
8. **Pay down UI consistency debt** through `AppConstants` migration and lint enforcement.

## Verification checklist after remediation

- `./run.sh build` succeeds with resolved dependencies.
- `./run.sh test` succeeds and includes graph transition, classifier, context, tool-executor, and cancellation tests.
- `./run.sh harness` succeeds offline; the script contains no references to absent suites.
- A Coder mutation performs at least one tool call through `AIToolExecutor`, commits one final assistant message, and reaches a graph terminal state before the transition limit.
- A Chat request never exposes mutation tools; ambiguous prompts take a safe deterministic route.
- Tool output, cancellation, timeout, and errors are represented as execution envelopes and persisted in telemetry without raw secrets.
