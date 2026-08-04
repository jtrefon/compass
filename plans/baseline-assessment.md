# Baseline Assessment: Agentic Performance

**Date:** 2026-07-15
**Objective:** Establish baseline metrics for the agentic coding pipeline using the online harness with the Kilo Code provider.

---

## Current Run

### Setup
- **Provider:** Kilo Code (`api.kilo.ai/api/openrouter`)
- **Model:** Default (`kilo-auto/balanced`)
- **Mode:** `.coder` — full tool access, agentic loop
- **Test:** `testHarnessReactTodoToSSRRefactor` — multi-phase (build React app → refactor to SSR)
- **Environment:** env vars unset (uses UserDefaults config), online mode via `COMPASS_RUN_ONLINE_HARNESS=1`

### Metrics captured
| Metric | Value |
|---|---|
| **Total elapsed** | 767 seconds (12.8 min) |
| **Phase 1 result** | 4 files created, but **timed out** after 300s idle |
| **Phase 2 result** | **Failed** — agent responded with text, no tool calls |
| **Files created** | `package.json`, `index.html`, `src/App.jsx`, `src/main.jsx` |
| **Agent behavior** | Sandbox path confusion → recovery → dropout → silent exit |

---

## Results

### Phase 1: React Todo App Build

```
[TOOL-EXEC] start tool=ls    → success (5ms) — explored directory
[TOOL-EXEC] start tool=write → FAILED (x4) — sandbox rejected paths starting with "/workspace/"
  ↑ Agent hallucinated project root as "/workspace/" instead of the temp directory
[TOOL-EXEC] start tool=write → FAILED — same path issue
[TOOL-EXEC] start tool=ls    → FAILED — tried to ls "/"
[AGENT IDLE 300s] no progress, no tool calls, no response
→ Timed out. But files WERE created (4 files found)
```

**Phase 1 checks:** 3/3 passed (package.json, index.html, App.jsx exist)

### Phase 2: SSR Refactor

```
[INFO][conversation] chat.user_message   ← Phase 2 prompt sent
[INFO][conversation] chat.assistant_message  ← immediate text response, NO tool calls
→ Agent did not execute any tools. Probably a refusal/"I cannot" message.
```

**Phase 2 checks:** 0/1 passed (server entrypoint not created)

### Tool Trail
- Total tool calls: 6 (ls: 2, write: 4)
- Failed tool calls: 5 (4 write sandbox rejects, 1 ls sandbox reject)
- Successful tool calls: 1 (exploratory ls)
- Zero successful file writes in the tool trail — yet files exist on disk (writes happened in a separate context window after recovery)

---

## What We Found

### Critical Issues

**1. Sandbox path hallucination (REPRODUCIBLE)**
The model initially wrote all files to `/workspace/...` instead of the actual project path. The sandbox rejected 4 writes before the model corrected. This wastes ~5 tool call cycles and confuses the agent.

**2. Phase 1 dropout after success (REPRODUCIBLE)**
After creating all 4 files correctly, the agent went silent for 300s. The timeout triggered. This is the classic "agent finishes work but doesn't signal completion" dropout — a high-priority fix target.

**3. Phase 2 context corruption (SUSPECTED)**
After Phase 1 timed out, the test proceeded to Phase 2. The agent responded instantly with a text-only message (zero tool calls). The model likely received the Phase 2 prompt in a corrupted or truncated context (post-timeout continuation flow). The `sendProductionMessage` timeout handler calls `manager.stopGeneration()` which may leave the conversation in an inconsistent state.

**4. Total runtime 12.8 minutes**
Most of this is idle waiting (300s Phase 1 timeout + build overhead). Actual productive work (tool execution) took ~50ms cumulative.

### Secondary Issues

- `ls /` attempted — agent tried to explore outside the sandbox root
- Phase 2 validation crashed with file-not-found error (expected, since no server file was created)
- Test cleanup/deferred execution after timeout may leave temp files
- Background work governor delayed indexing repeatedly during the run

---

## What We Tried

| Session | Approach | Result |
|---|---|---|
| 2026-07-15 baseline | `testHarnessReactTodoToSSRRefactor` via Kilo Code | Phase 1 partial (files created but timeout), Phase 2 failed |
| 2026-07-15 fix-run | Same test + path fix + timeout reduction + stopGeneration cleanup | Phase 1 improved (no sandbox rejections, files created), Phase 2 still failed |

---

## Decision: Re-architect to State Machine (not fix loop)

**Context:** We previously had LangGraph-style state machine orchestration. It worked well. We simplified to a fixed tool loop for "faster and more focused execution." The result was the opposite: model dropout, dead loops, 300s idle timeouts, path hallucinations, and corrupted multi-phase execution.

**Decision:** Do NOT fix the loop incrementally. Re-architect to a Plan→Execute→Review state machine. The model transitions between phases via structured output (`ReviewDecision`). The orchestrator routes accordingly.

**Why not fix the loop:**
- Dropout is intrinsic: a fixed loop can't know when the model is done without a completion signal
- The bool flag/isSending approach already failed (stuck at true)
- Three independent failure modes all trace to the same root cause: no structure
- We've already confirmed the fix path (state machine) worked before, and the fix-run proved the simple loop still has issues

**Why not rebuild LangGraph:**
- We already have the infrastructure: `OrchestrationRunSnapshot`, `ConversationStreamStore`, `ToolLoopHandler`
- The state machine pattern is simple (3 nodes, 1 routing edge) — not a full graph framework
- Borrowing LangGraph for Swift would require a Swift port, which doesn't exist at production quality
- What we need is the **pattern**, not the framework

## Remaining priority fixes

| Fix | Status | Result |
|---|---|---|
| **Path hallucination** | ✅ **RESOLVED** | Added `hallucinatedRoots` normalization to `PathValidator`, strengthened prompt, updated tool param description. Zero sandbox rejections in fix-run. |
| **Harness heartbeat** | ✅ **RESOLVED** | Reduced idle timeout from 300s to 60s across all `sendProductionMessage` and `waitForConversationToFinish` calls. Faster feedback. |
| **StopGeneration cleanup** | ⚠️ **PARTIAL** | Added `clearDraft()`, `cancelledToolCallIds.removeAll()`, `draftAssistantMessageId = nil` to `stopGeneration()`. Phase 2 still produces no tool calls after Phase 1 timeout. |
| **Phase 1 dropout** | ❌ **NOT RESOLVED** | Agent creates files correctly but `isSending` stays `true` until timeout. Requires Review node (structured completion signal). |
| **Phase 2 context corruption** | ❌ **NOT RESOLVED** | After Phase 1 timeout → stop → continuation, Phase 2 prompt gets text-only response with zero tool calls. The pipeline state reset is still incomplete. |

### Remaining priority fixes

1. **Add Review node for structured completion** — The model needs to explicitly signal "I'm done" via structured output (`ReviewDecision`). This is the LangGraph state-machine pattern from the proposal. Until this is implemented, the fixed loop will always have dropout issues.

2. **Fix continuation path for real** — After `stopGeneration()`, the conversation manager's internal state (especially the `historyCoordinator` and the streaming pipeline) needs a complete reset before a new `sendMessage()` can work. Currently, stale draft state corrupts the context assembly for the next turn.

3. **PathResolver service integration** — The `SandboxPathResolver` has been created but not yet wired into the tool execution layer. The `PathValidator` was fixed (the direct cause of the rejection), but the cleaner long-term solution is a single `PathResolver` that both `Sandbox` and `PathValidator` delegate to.

---

## Known Recurring Issues (Tracked)

| Issue | Observed this run | Status |
|---|---|---|
| **Tool call dropout** | ✅ Yes — Phase 1, 300s idle after file creation | Confirmed |
| **Graph exit / no tools called** | ✅ Yes — Phase 2, responded with text only | Confirmed |
| **Sandbox path wrong** | ✅ Yes — `/workspace/` instead of actual path | Confirmed |
| Context truncation amnesia | ⚠️ Possible — Phase 2 may be affected | Suspected |
| KV cache invalidation | Not measurable from this run | Unknown |
| Final answer wiped | N/A — test didn't reach completion | N/A |
| Raw tool markup leak | Not observed | Clean |

---

## Build vs Borrow Analysis

### Candidates evaluated

| Solution | Language | Stars | Maturity | Can we use it? |
|---|---|---|---|---|
| **LangGraph** | Python | 37.4k | Production (553 releases) | No — Python-only, would require subprocess bridge |
| **LangGraph.js** | TypeScript | Active | Production | Technically possible via JS bridge, but adds complexity |
| **Swift LangGraph port** | Swift | 0 | Nonexistent | No community Swift agent framework exists |
| **Apple AI frameworks** | Swift | — | New (WWDC 2025+) | Too nascent, not designed for tool-calling agents |
| **Build our own (Plan→Execute→Review)** | Swift | — | Already have 80% | Missing Review node + routing — ~1 week of work |

### Verdict: Build (not borrow)

**LangGraph can't be used** — it's Python, and we're a native macOS Swift app. Running Python as a subprocess for orchestration would be heavier than the orchestration itself. LangGraph.js is possible via JavaScriptCore but adds a full JS runtime dependency for what amounts to a simple 3-state machine.

**Nobody has built a Swift LangGraph** — the Swift AI ecosystem is essentially empty. There's no foundation to borrow from. If we borrow anything, we'd be committing to a dependency that has zero community support.

**We already have 80% of what we need**:
- `ConversationStreamStore` — durable state ✅
- `OrchestrationRunSnapshot` — state serialization ✅
- `ToolLoopHandler` — execution node ✅
- `AIToolExecutor` — tool execution ✅
- `EventBus` — event routing ✅
- Missing: Review node + structured routing + AgentOrchestrator mediator

### What we'd build

The proposal's Plan→Execute→Review state machine is 3 protocol conformances + 1 mediator. Not a graph framework — just the pattern that worked when we had LangGraph. Estimated effort: ~1 week (Phase 3 from the proposal).

## Next Steps

1. ✅ **DONE** — Path hallucination fixed
2. ✅ **DONE** — Harness heartbeat reduced (60s instead of 300s)
3. 🔜 **NEXT** — Implement Plan→Execute→Review state machine (see [architecture spec](architecture-agentic-state-machine.md))
4. ⏳ — Re-run baseline to measure improvement after state machine implementation
