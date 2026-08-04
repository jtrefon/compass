# Agentic Architecture Review — July 2026

> **Trigger:** 262k-context explosion on a simple "review this plugin" request. Zero output delivered. System in functional collapse.

## Evidence from the latest session (EA96741C)

**User sent 4 messages.** Only 2 got any agent response.

| # | User | Agent |
|---|---|---|
| 1 | "hi" | ✅ "Hi! 👋 How can I help you today?" |
| 2 | "can you review career-register plugin for me?" | ❌ No deliverable. 64 tool calls consumed. Stall summary only: *"Completed tools: ls × 2."* |
| 3 | "hi" (retry after silence) | ❌ No response |
| 4 | "could you review career register plugin for me?" | ❌ No deliverable |

**Tool call breakdown:** `ls`×20, `search`×16, `read`×14, `bash`×8, `glob`×6 = **64 tool calls**.

**Assistant content:** 18 of 22 tool-call batches had EMPTY content. Only 2 had text: *"I'll review the career-register plugin. Let me start by exploring its structure and code."* and a variant.

**Analysis:** The while-loop produces empty-content tool-call batches. The stall-detection fires. The system either loops infinitely (262k tokens) or finalises with a stall summary instead of the user's actual deliverable. The user got **zero useful output** from 64 tool calls.

---

## Architecture: The Dual Recovery Trap

The current system has a **graph wrapping a loop**, both of which can independently detect stalls and initiate recovery. This is the root cause of the collapse.

```
OrchestrationGraphRunner  (outer — up to 64 graph transitions)
 ├─ DispatcherNode         → 1 LLM call (InitialResponseHandler)
 ├─ ToolLoopNode           → calls ToolLoopHandler.handleToolLoopIfNeeded()
 │   └─ ToolLoopHandler.while-loop  → up to 50 internal LLM calls
 │       + 22 stall-detection conditions
 │       + 6 recovery strategies
 │       + custom tool-filtering for mutation/recovery
 │       + plan nudges, convergence tracking, read-caching
 │       + RECURSIVE self-call up to 3 levels deep (line 1514)
 ├─ OrchestrationReviewerNode → checks plan completeness, decides loop/exit
 ├─ BranchReviewNode       → checks execution signals, can re-route to ToolLoopNode
 ├─ EmptyResponseRecoveryNode → patches empty dispatcher responses
 └─ FinalResponseNode      → calls FinalResponseHandler (1-2 LLM calls)
```

**Three overlapping review mechanisms decide "stop or keep going":**

| Layer | Mechanism | Files |
|---|---|---|
| ToolLoopHandler | 22 inline stall-detection conditions inside while-loop | `ToolLoopHandler.swift` (2961 lines) |
| OrchestrationReviewerNode | Plan completeness evaluation after every ToolLoopNode cycle | `OrchestrationReviewerNode.swift` |
| BranchReviewNode | Execution-signal evaluation (missing artefacts, unfinished) | `BranchReviewNode.swift` |

**The failure mode:** ToolLoopHandler detects a stall (e.g. empty for 3 consecutive batches, line ~61: `emptyResponseStallThreshold = 3`). It breaks out of its while-loop, returning a `ToolLoopResult` containing the last `currentResponse`. This response is the LLM's last output — which in session EA96741C was a **stall summary**: *"Completed tools: ls × 2."* The graph receives this, passes it to `OrchestrationReviewerNode`, which sees the plan isn't complete, routes BACK to `ToolLoopNode`, and the cycle restarts.

**The tool loop's while-loop has already exhausted its own recovery budget** (50 iterations total, stalled multiple times). But the graph's `OrchestrationGraphRunner` reverts to its own counter (64 transitions) and keeps going. This is why the user sees 262k tokens with zero output — the outer graph keeps routing back to the tool loop, and the tool loop keeps running empty-content iterations until the graph hits its 64-transition limit.

---

## The 8.5k Token Baseline

Your prompt budget for a "hi" message is approximately:

| Component | Est. tokens |
|---|---|
| base-system-prompt.md | ~500 |
| tool-system-prompt (full or concise) | 300–1,500 |
| 12 v3 tool docs (read, write, edit, ls, glob, search, rm, context, web_search, web_fetch, bash, plan) | ~2,000 |
| mode-coder.md (expanded with review/audit section) | ~700 |
| project-root-context.md (expanded with bash-cwd rules) | ~400 |
| ProjectShapeSummary (WordPress → 3 plugins listed) | ~150 |
| tool-execution-envelope.md | ~200 |
| reasoning prompts | ~300 |
| OS context | ~50 |
| **Subtotal — prose prompt** | ~4,500–6,000 |
| Function-calling JSON schemas (15 tools × ~500 bytes each) | ~7,500 (provider-side) |
| **Total first-turn** | **~8,500–12,000** |

The function-calling schemas are sent by the LLM provider layer, not our prompt. We can't reduce those without reducing the tool count. The prose portion (~5k) is reasonable for an agentic IDE — this is the cost of having tools.

---

## How We Got Here (Timeline)

Based on the git history and code artefacts:

1. **Originally:** A fully functional graph-based architecture. Each node (Dispatcher, Executor, Reviewer, FinalResponse) had clear responsibilities. State transitioned via `OrchestrationState.nextNodeId`. Clean separation of concerns.

2. **Fork 1:** Someone reintroduced `ToolLoopHandler` — a while-loop-based handler with its own LLM dispatch, tool execution, and stall detection. This was placed INSIDE `ToolLoopNode` (inside the graph). The graph's `ExecutorNode` was replaced by `ToolLoopNode` → `ToolLoopHandler`.

3. **Fork 2:** The graph's original executor state machine (`makeStateMachineGraph`) was left as dead code. A new `BranchReviewNode` was added for recovery.

4. **Fork 3:** `MessageTruncationPolicy`, `ToolLoopUtilities`, `FollowUpMessageAssembler`, `LoopBreakController`, `PipelineProcessor` — all added as utility layers around the already-overloaded ToolLoopHandler.

5. **Fork 4:** The `Conversation/` stack (ConversationCoordinator, ConversationStreamStore, SessionRegistry, PromptProjector) was deleted. These handled session persistence and prompt projection. Their replacement (`SessionManager`) was never fully wired.

6. **Current state:** Graph-wrapss-loop architecture with triple recovery. Session persistence broken. Tool-call context leaking across sessions via the vector store. History erasure in recovery paths. 2961-line monolith performing most orchestration.

---

## Is It Worth Rescuing?

**Yes, but not by patching the current architecture.** The graph-wrapss-loop hybrid is fundamentally broken because of the **double-recovery trap**. No amount of per-condition tweaking (read-only guards, stall thresholds, recovery nudges) can fix the architectural problem that two independent recovery systems are routing to each other.

### Option A: Restore the original graph (Recommended)

1. **Delete `ToolLoopHandler` entirely.** Its 2961 lines are a red herring — the graph already has all the nodes needed for execution control. The while-loop inside ToolLoopNode was a mistake.

2. **Restore ToolLoopNode to its original form:** one LLM call → execute tool calls → emit result. No internal while-loop, no stall detection. ToolLoopNode is called repeatedly by the graph's outer loop via `OrchestrationReviewerNode`'s routing decision.

3. **Consolidate the three review mechanisms into one:** Move all "should we continue?" logic into `OrchestrationReviewerNode`. Delete `BranchReviewNode`. Delete the 22 stall-detection conditions from the now-deleted ToolLoopHandler.

4. **Restore session persistence:** Re-implement `ConversationStreamStore` (or properly wire `SessionManager` with lifecycle hooks). Delete the vector store cross-session ingestion — it's the source of context poisoning.

5. **Reduce tool count from 15 to 8:** Keep only `read`, `edit`, `write`, `ls`, `glob`, `search`, `bash`, `context`. Drop `rm`, `web_search`, `web_fetch`, `plan`, `pinned_rule_add/remove/list`, `research`. The research subagent and pinned-rules features are not delivering value.

**Effort:** ~2 weeks. **Risk:** Medium — the graph infrastructure is intact. The damaged part is ToolLoopHandler. **Reward:** High — restores the functional system.

### Option B: Keep the loop, delete the graph (Aggressive)

1. **Delete the entire `Orchestration/` directory.** The graph adds no value — ToolLoopHandler already makes all decisions, and the graph just re-routes the same state back to ToolLoopNode.

2. **Simplify ToolLoopHandler to ~200 lines.** Remove stall detection, recovery, plan nudges, convergence tracking. Let the while-loop run for `maxIterations` turns and emit whatever the model produced. If the model stalls for 3 turns, break and report. No recovery, no re-routing, no nudge injection.

3. **Same session persistence + tool count reduction as Option A.**

**Effort:** ~1 week. **Risk:** High — ToolLoopHandler is deeply embedded. Deleting Orchestration may break the send flow. **Reward:** Medium — simpler but less controllable.

### Option C: Nuke and start over (Nuclear)

1. **Delete everything** from `Services/CloudPipeline/`, `Services/Orchestration/`, and `Services/Conversation/`.

2. **Adopt a proven agentic architecture** — opencode's tool loop, Aider's edit-apply loop, or Cline's task-orchestrator pattern. These are production-tested, well-documented, and don't have double-recovery.

3. **Port the tool definitions** (read, write, edit, ls, glob, search, bash) — those are the only components that work correctly.

**Effort:** ~4 weeks. **Risk:** Low — you're starting from known-good patterns. **Reward:** Highest — clean slate without architectural debt.

---

## Recommendation

**Option A — restore the original graph.** The concrete steps are:

1. **Delete `ToolLoopHandler`** (reduces 2961 lines to 0, eliminates the while-loop-inside-graph).

2. **Rewrite `ToolLoopNode`** to: send one LLM message → execute tool calls → return result. No internal loop. Let the graph handle iteration.

3. **Delete `BranchReviewNode` and `EmptyResponseRecoveryNode`.** Move their logic into `OrchestrationReviewerNode`.

4. **Set `maxIterations = 8`** on the graph runner (currently 64). A review task should take at most 5 LLM turns + 5 tool-execute rounds = 10 graph transitions. 64 is absurd for any task.

5. **Wire `SessionManager`** with `restoreSession` in `ConversationManager.init` (done in the last fix round) and `saveSnapshot` on `didEnterBackground` and `sendMessage` completion.

6. **Remove vector store cross-session ingestion.** The `VectorStoreEmbeddingCoordinator` should only store embeddings for the CURRENT session. Or delete it entirely — the `context` tool has never been demonstrated to improve agent behaviour.

7. **Reduce tool list to 8** (read, edit, write, ls, glob, search, bash, context). The 15-tool array sends ~7.5k bytes of JSON schemas to the LLM on every turn.

**These 7 steps can be implemented in order.** Step 1 alone (deleting ToolLoopHandler) will stop the infinite-loop behaviour immediately — the graph will return whatever the ToolLoopNode produces after one LLM call, without spending 50 iterations in an internal while-loop.

---

## What NOT to do

- **Do not add more stall-detection conditions to ToolLoopHandler.** It already has 22. Adding more will not fix the architectural problem.
- **Do not add more recovery prompts.** The `buildFocusedExecutionMessages` family already represents ~500 lines of prompt-injection code. Recovery should be structural (the graph routes), not textual (prompt injection).
- **Do not tweak tool descriptions or parameter schemas.** The tools themselves work correctly (ls lists dirs, search finds code, read returns content, edit patches files). The problem is the orchestration, not the tools.
- **Do not delete the tools.** The `edit` old_string/new_string mode (§1), the WordPress index exclusion (§7), and the glob path-optional (§5) are all correct and improve tool quality. Keep them.