# Agentic Context Access Layer — Design & Implementation Plan

> **Purpose:** This document is the single source of truth for fixing the agentic
> inefficiency / context-loss failures observed in the July 11 session
> (`sandbox/todo-app/.ide/logs/conversations/5124BEA4-…`). It is written to
> survive a context compaction so implementation can start from scratch.
>
> **Status:** Network-resilience work is DONE (recorded in §6, do not redo).
> The Context Access Layer (§4, L0–L5) and the mode/plan-loss fix (§7) are the
> open build items.

---

## 0. The failure we are fixing (evidence from session 5124BEA4)

Timeline (UTC), Jul 11, `conversation.ndjson`:

| Time | Event |
|---|---|
| 09:34:43 | `conversation.start` — user asks to verify user-management |
| 09:41–09:44 | Model *already assesses* UI as "feature-complete… clean and reasonably modern… same-screen management… table + add/edit form on same page" |
| 09:46:02 | user "ok, get us there please" |
| 09:46:15 | `chat.error`: **"Internet connection appears to be offline"** (connectivity drop #1) |
| 09:46:58 / 09:51:11 | user "continue" ×2 (manual nudge) |
| 10:13:49 | `chat.error`: **"Internet connection appears to be offline"** (drop #2) |
| 10:14:37 | user: **"you just crashed, please recover and continue"** → app CRASHED on the drop |
| 10:14–10:54 | heavy tool loop: 11 role-support files written, `tsc` run — task essentially complete |
| 10:54:04 | last successful tool call (`tsc`, 639 bytes) |
| 10:54:04 → 10:57:56 | **~3m52s silence** |
| 10:57:56 | `chat.error`: **"Kilo Code request timed out after 60s"** (`E86338C8`) → FINAL FAILURE |

**Quantified waste (the core complaint):**
- Runtime **~1h23m** for a "make the user table + modal edit work" task.
- **311 tool calls**: 150 `read`, 101 `bash`, 30 `edit`, 21 `ls`, 7 `search`.
- `src/api/userService.ts` read **36×**; `src/components/UserManagement.tsx` read **24×**.
- Temp "view" files `_userform_view.txt` (10×) and `_um_view.txt` (8×) created then
  re-read — the model *wrote output to a file to "see it clearly"* (confirmed in its
  10:53 message: *"Let me write the output to a file to see it clearly"*).
- **54 unique files** touched (full backend rebuild for an already-complete UI task).
- Context window: **262k model, session used < 50%** → trimming is NOT the constraint.

**The user's three explicit findings:**
1. Model failed at the end to comply with the request (final timeout → no deliverable).
2. Excessive tool use; model does a lot of work / takes a long time for simple tasks.
3. The model "can't access everything" — it re-reads and uses temp-file hacks.

---

## 1. Symptom → root-cause → fix map

| # | Symptom | Root cause (code) | Fix |
|---|---|---|---|
| S1 | Connectivity drops crashed the app | No network detection/retry in `sendMessageWithRetry` (pre-fix) | **DONE** — §6 escalation retry + banner |
| S2 | 60s timeout → final non-compliance | Timeout not retried with escalation pre-fix; also masked by S3 thrash | §6 (done) + §4 L0–L5 so model isn't thrashing when timeout hits |
| S3 | 36× re-read of one file | `OpenAICompatibleChatService` flat 12k cap on every tool result (RC-A) → model never sees full file | §4 L0–L2 |
| S4 | Temp-file-as-context hack | Same cap on bash output → model can't see full output | §4 L1 (recoverable truncation) |
| S5 | Scope creep / no done-state | No definition-of-done / continuation guard; over-engineering | §4 L3 (subagent scope) + §7.3 |
| S6 | Mode/plan loss @09:47 ("I'm read-only… earlier turn errored out") | Error recovery didn't restore mode + plan handoff | §7 |
| S7 | Silent truncation → agent "lies" | `…[truncated]` suffix, no recovery path | §4 L1 (actionable hint) |

---

## 2. Root-cause analysis (code-mapped, verified)

- **RC-A (the dominant bug — CORRECTED during implementation):** the per-tool
  truncation is **not** `MessageTruncationPolicy` (that class only truncates the
  per-iteration `followupMessages` at `ToolLoopHandler.swift:931`, never the tool
  results themselves). The real cap is in the request-mapping path of
  `OpenAICompatibleChatService.swift`:
  `mapValidToolMessage` (`:394`) and `mapFallbackToolMessage` (`:400`) call
  `truncate(message.content, limit: maxToolOutputCharsForModel)` **on every
  committed tool message, every send**, and `truncate` (`:405`) returns
  `String(text.prefix(limit)) + "\n\n[TRUNCATED]"` — model-independent, no recovery
  path. `maxToolOutputCharsForModel` (`:410-411`) is a flat **12,000 chars**, ignoring
  `ModelContextProfile` (262k window, `.slidingWindow`). So the model only ever sees
  the first 12k chars of any tool result → files/big outputs get silently truncated
  → re-read storms + temp-file hacks. **Fix targets `mapValidToolMessage` /
  `mapFallbackToolMessage` (L0/L1), not `MessageTruncationPolicy`.**
- **RC-B:** Tool results ARE persisted correctly (`ChatHistoryCoordinator.commitToolResult`
  `:107-122`, by `toolCallId`), but they are **truncated before storage at send
  time**, so the truncation is baked in and irreversible.
- **RC-C:** Auto context injection was removed during the consistency refactor.
  `AIInteractionCoordinator.swift:99` `let augmentedContext: String? = nil` is dead
  code; `OpenAICompatibleChatService.buildFinalMessages` (`:317-338`) explicitly does
  **not** prepend context (to keep the system prefix stable for cache). The planned
  replacement context API (`ConversationContextStore.projectedContext(for:)` +
  `ProviderContextAdapter`, per `provider-context-caching-research.md` §7.2) was
  **never finished**. Only a passive `ContextTool` returning 500-char snippets exists.
- **RC-D (the inconsistency):** `ConversationSendCoordinator.trimOldMessagesIfNeeded`
  (`:280-284`) does `guard historyCoordinator.strategy == .compaction else { return }`
  — i.e. for `.slidingWindow` models it **skips compaction**. But
  `MessageTruncationPolicy` is **profile-blind** and truncates tool results for
  *every* model. So the per-tool cap contradicts the policy the app already trusts.
- **RC-E:** `ReadFileTool` (`ReadFileTool.swift:22-28`) **already supports
  `start_line`/`end_line`** pagination, but it reads the whole file into memory then
  slices, and the 2000-char post-cap defeats ranged reads anyway.
- **RC-F:** No subagent/agent-spawning mechanism exists anywhere in the agentic loop
  (grep: none). Exploration pollution accumulates in the main context.
- **RC-G:** Local MLX inference (`LocalModelProcessAIService`,
  `InlineCompletionEngine`/`CompletionInferenceService`) and FAISS
  (`VectorStoreEmbeddingCoordinator`, `CFAISSWrapper`) **exist** but are not used to
  summarize excessive tool output.
- **RC-H:** Error recovery (post network-drop) does not re-inject mode + plan +
  todos into the resumed prompt (RC for S6).

---

## 3. Design principles (world-class, from industry research)

Research baseline (2026): Claude Code, opencode, Aider, Cline, Roo, Cursor/Windsurf.

1. **Never silently lose data.** Silent truncation is the worst failure mode
   ("Tool-Result Truncation: The Silent Bug That Makes Agents Lie") — the agent
   answers confidently from half-truth and never knows. Always make loss *recoverable*.
2. **Recoverable over destructive.** On overflow: offload full output to disk, return
   a preview **+ an actionable hint** ("read with range", "delegate to subagent"),
   never a bare `[truncated]`.
3. **Isolate noisy work.** Exploration / large-result digestion runs in a **subagent
   with its own context window**; only a bounded summary returns to the parent.
4. **Summarize, don't discard.** Excessive *structured* output (compile/test logs)
   is distilled by a **local model** into actionable errors, preserving information.
5. **Movable traversal.** Files are navigated like pages (`start_line`/`end_line`,
   `char_offset` fallback for minified files) with continuation footers.
6. **Window-aware.** For large-window / sliding-window models with headroom, do not
   truncate at all.
7. **Stable prefix.** Any injected context (repo-map, hints) must not scramble the
   cached system prefix (this is *why* auto-injection was removed — the new design
   must respect it).

---

## 4. The Context Access Layer (CAL) — architecture

A layered replacement for the blunt `MessageTruncationPolicy` cap. Each layer is
independently shippable.

### L0 — Window-aware gating (baseline, kills S3/S4 immediately) — IMPLEMENTED

**Goal:** For a large-window / sliding-window model, never truncate tool results.

- **Implemented in the request-mapping path**, not `MessageTruncationPolicy` (which
  only truncates per-iteration `followupMessages`). `ToolOutputArchive.effectiveToolOutputLimit(modelID:)`
  (added to `MessageTruncationPolicy.swift`) returns `windowSize * 4` for
  `.slidingWindow` models with `windowSize >= 128_000` (e.g. Claude 200k → 800k-char
  cap), and a proportional floor (`max(12_000, windowSize/8)`) otherwise.
- `OpenAICompatibleChatService.buildOpenRouterMessages` now resolves the model and
  threads `model` + `projectRoot` through `mapOpenRouterChatMessage` →
  `mapValidToolMessage`/`mapFallbackToolMessage` → `truncateToolOutput`, which uses
  the window-aware limit instead of the old flat 12k `maxToolOutputCharsForModel`.
- `MessageTruncationPolicy.truncateToolResult` (followupMessages only) is left as a
  small safety net; aligning it with the window-aware limit is a deferred consistency
  item, not required for the fix.
- **Files:** `OpenAICompatibleChatService.swift` (`buildOpenRouterMessages`,
  `mapValidToolMessage`, `mapFallbackToolMessage`, `truncateToolOutput`),
  `MessageTruncationPolicy.swift` (`ToolOutputArchive`), `ModelContextProfile.swift`.

### L1 — Recoverable truncation (kills S4/S7; replaces silent loss)

**Goal:** When a result still exceeds budget, offload full content to disk and return
a preview + an *actionable* hint. Steal opencode's context-aware hint pattern.

- Add a **tool-output retention dir** (`.ide/tool-output/`, 7-day retention, like
  opencode). On overflow:
  1. Write the **full** output to `<runId>/<toolCallId>.txt`.
  2. Return: `head(preview)` + (for logs) `tail(preview)` + a structured footer:
     ```
     [tool output truncated at N chars; full saved at <path>]
     Next: read with start_line/end_line, or delegate to the research subagent.
     ```
  3. Hint is **context-aware**: if the agent has the research-subagent tool, the hint
     says *"delegate to the research subagent — do NOT re-read the full file yourself"*
     (opencode's exact wording); otherwise *"read with start_line/end_line"*.
- `maxToolResultCharacters` becomes a **preview size**, not a destructive hard cap.
- Emit a `ContextLogEvent`/telemetry marker when overflow-offload occurs (for harness
  assertions).
- **Files:** `MessageTruncationPolicy.swift` (rewrite `truncateToolResult`),
  new `ToolOutputArchive` helper, `ToolLoopConstants.swift` (rename constant semantics).

### L2 — First-class movable traversal (kills S3 re-reads)

**Goal:** Make ranged reads the default instructed path; add `char_offset` fallback.

- `ReadFileTool` already has `start_line`/`end_line` (`ReadFileTool.swift:22-28`) —
  **promote it**: update the tool `description` and `SystemPromptAssembler` to instruct
  ranged reads for files > ~200 lines, and to use `end_line` to bound.
- Add `char_offset`/`char_limit` parameters (fallback for minified single-line files —
  Claude Code's known gap, Issue #41092).
- **Stream** the file (`FileHandle`/line iterator) instead of
  `fileSystemService.readFile(at:)` loading the whole file, so large reads never blow
  memory and the cap is naturally a *range* concern, not a truncation.
- Every overflow/ranged read appends a continuation footer:
  `(Showing lines X–Y of N. Use start_line=Z to continue.)`
- **Files:** `ReadFileTool.swift`, `FileSystemService`, `SystemPromptAssembler.swift`,
  tool-reference prompts (`Tools/v3/read`).

### L3 — Loop-break controller & single-message assembly (Phase B) — IMPLEMENTED

**Goal:** Replace 5 contradictory follow-up messages with a single coherent instruction.
Let the model cleanly exit when it signals done.

- **`LoopBreakController.decide(TurnState) → Decision`** — a single decision point
  that evaluates: wall-clock budget, reads-without-mutation count, iteration cap,
  work-performed signals, completion signals, pending execution signals. One decision
  per turn, never contradictory.
- **`FollowUpMessageAssembler.assemble(decision:state:) → ChatMessage?`** — produces
  exactly ONE message (or nil to stop). Replaces 5 individual message builders
  (`toolCompletionFeedbackMessage`, `planExecutionNudgeMessage`,
  `planResearchNudgeMessage`, `toolLoopStepUpdateInstructionMessage`,
  `toolLoopContextMessage`).
- **`ChatPromptBuilder.shouldForceExecutionFollowup` reordered** — checks
  `indicatesWorkWasPerformed` FIRST, then pending signals, then completion signals.
  Natural model language like "I have done X. Let me verify." no longer triggers an
  unwanted force-re-prompt (the "let me" no longer overrides the "I have done").
- **`shouldInjectStepUpdateInstruction` fixed** — removed `iteration == 1` and
  `iteration % 4 == 0` triggers. Now fires only on failure recovery and read-only
  stall detection. No more fixed-schedule distraction.
- **`BranchReviewNode` simplified** — only re-enters execution on `hasToolCalls` or
  `missingClaimedArtifacts`. Capped `indicatesUnfinished` re-entry at
  `maxNeedsWorkReentries = 2` (with `hasChecklist` guard).
- **`readOnlyLoopToolNames` fixed** — now includes `MutationTools.readOnlyNames`
  (the actual tool names `"read"`, `"ls"`, `"glob"`, etc.) in addition to the legacy
  `"read_file"`/index variants. The existing read-only stall now fires for the real
  tool names.
- **Files:** `ToolLoopHandler.swift` (rewritten follow-up assembly, new
  `LoopBreakController`/`FollowUpMessageAssembler` types), `ChatPromptBuilder.swift`
  (reordered check), `BranchReviewNode.swift` (simplified routing),
  `ToolLoopConstants.swift` (`maxNeedsWorkReentries`).

### L4 — Convergence detector (Phase C) — IMPLEMENTED

**Goal:** Detect when the model is looping without making progress and force a
graceful exit with a deterministic summary.

- **Wall-clock budget:** `ToolLoopConstants.maxToolLoopDuration = 600s` (10 min).
  After this, `requestFinalResponseForStalledToolLoop` fires and the loop breaks.
- **Reads-without-mutation stall:** `maxReadsWithoutMutation = 15`. If the model
  makes 15+ consecutive read-only iterations without a successful mutation, the
  convergence detector fires and breaks to a final summary.
- **Tracking:** `consecutiveReadsSinceLastSuccessfulMutation` reset on any
  successful mutation, incremented when all tool calls in an iteration are read-only.
- **Both share the existing `requestFinalResponseForStalledToolLoop` path** —
  already battle-tested, produces a `deterministicSummary` or model response.
- **Test:** `testConvergenceDetectorFiresAfterExcessiveReadsWithoutMutation`
  validates the 15-read threshold with a scripted harness.
- **Files:** `ToolLoopHandler.swift` (convergence tracking + stall checks),
  `ToolLoopConstants.swift` (`maxReadsWithoutMutation`, `maxToolLoopDuration`).

### L5 — ContextTool session orientation (Phase D) — IMPLEMENTED

**Goal:** When the model calls `context()` mid-session to "recall", give it a
lightweight orientation (plan progress + files read) so it doesn't need to
re-read everything manually.

- `ContextTool.execute()` now prepends a **session context** section:
  - Plan tasks: `N/M complete` (from `ConversationPlanStore`)
  - Files read this session (up to 10, from `ToolFileAccessLedger.shared.readPaths`)
- Fallback: if the vector store is unavailable, the orientation is still returned.
- When the vector store has relevant RAG results, they follow the orientation.
- **Files:** `ContextTool.swift`, `ToolFileAccessLedger.swift` (added `readPaths`).

### L6 — Subagent context isolation (future work — not yet implemented)

**Goal:** A read-only research/explore subagent with its **own context window**
handles exploration legs and large-result digestion, returning a bounded summary.

- New `ResearchSubagent` built on existing primitives: a nested
  `ToolLoopHandler` + its **own** `ChatHistoryCoordinator` (fresh committed chain) +
  an `AIService` call. Scoped to read-only tools (`read`, `search`, `ls`, `context`).
- **Handoff contract** (the part that makes delegation reliable, per claudify.tech):
  - *Brief:* explicit goal + concrete file paths / error text / acceptance criteria
    (avoid "starved prompts").
  - *Output contract:* structured summary — `findings`, `files_touched`, `errors`,
    `next_step` — bounded to e.g. 2k tokens.
  - *Guardrails:* `maxTurns` cap; optional `isolation: worktree` only for mutating
    agents (not needed for read-only); **fan-out cap** to avoid runaway cost.
- Parent delegates: "find where auth is implemented", "summarize this 4k-line compile
  log", "explore the user-service stack" — keeping the noisy middle out of the 262k
  parent window.
- The subagent result is committed to the parent chain as a single compact
  `tool`/`assistant` message (not raw exploration).
- **Files:** new `Services/CloudPipeline/ResearchSubagent.swift` (+ agent def),
  wire into `ToolLoopHandler` delegation logic, `ConversationPolicy` (allow
  subagent tool), `ToolLoopConstants` (maxTurns/fan-out caps).

### L4 — Local-model summarization for excessive structured output (kills S4 root)

**Goal:** Distill compile/test/log output via the **existing local MLX model**
instead of discarding 96% of it.

- When a tool result is a structured log (compile/test/stack trace) and exceeds a
  threshold, route it through `LocalModelProcessAIService` (or
  `InlineCompletionEngine`) to produce: *"3 errors: <file:line> <msg>; root cause
  likely X"*. The distilled summary (not the raw 50k chars) goes to the cloud context.
- Preserves information vs. truncation; cheap (local, no API cost).
- Optional: FAISS retrieval (`VectorStoreEmbeddingCoordinator`) lets the agent request
  specific file *regions* on demand ("give me the chunks about `login()` in
  `UserService.ts`").
- **Files:** `LocalModelProcessAIService.swift` (add a `summarize(log:)` entry),
  `MessageTruncationPolicy.swift` (call summarizer in L1 offload path),
  `VectorStoreEmbeddingCoordinator.swift` (region retrieval API).

### L5 — Orientation + compaction (kills S5 drift; system hygiene)

- **Repo-map (Aider-style)** as default orientation context: tree-sitter symbols →
  PageRank over the reference graph → binary-search-fit to a token budget,
  personalized toward chat/mentioned files (~1k tokens replaces ~12k of file reads).
  Replace the current directory-dump / full-read orientation.
- **Compaction with rehydration:** structured summary
  (intent / decisions / files / errors / next-step), then re-read the few most-recent
  files and restore todos/plan (the "rehydration" pattern).
- **Dedup repeated read blocks** (Cline): replace older duplicate file-content blocks
  in history with pointers when it saves >30%.
- **Fix the overflow-estimation gap** (opencode Issue #10634 analog): estimate the
  *upcoming* context size including just-produced tool outputs **before** the next
  step, not just the last step's reported usage, so a subagent's large return can't
  silently blow the next request.
- **Files:** new `RepoMapBuilder.swift` (tree-sitter), `ChatHistoryCoordinator.swift`
  (rehydration + dedup), `ConversationSendCoordinator.swift` (overflow estimate).

---

## 5. How CAL maps to each symptom

- **S3 (36× re-reads)** → L0 (no truncation for 262k) + L1 (recoverable, full on disk)
  + L2 (ranged reads as default).
- **S4 (temp-file hack)** → L1 (preview + hint instead of dumping to disk manually) +
  L4 (local summarization of logs).
- **S5 (scope creep)** → L3 (subagent scoped brief) + L5 (repo-map orientation,
  done-state detection).
- **S7 (silent lie)** → L1 (actionable hint, never bare `[truncated]`).
- **S2 (final timeout / non-compliance)** → L0–L5 stop the thrash so the final request
  isn't competing with a 70-min re-read storm; plus the §6 network retry keeps the
  request alive.
- **S6 (mode/plan loss)** → §7, reinforced by L3's explicit handoff contract.

---

## 6. Network resilience — ALREADY IMPLEMENTED (do not redo)

Recorded so it isn't lost on compaction. Shipped in the prior session:

- `ProviderIssueStatusEvent.StatusKind` gained `.networkOffline`.
- `AIInteractionCoordinator.sendMessageWithRetry` refactored: `networkRetryResult`
  classifies connectivity errors and applies an **escalating schedule**:
  **1s × 10s → 5s × 1min → 15s × 5min** (≈6.5 min budget), self-terminating.
- Detection (`isNetworkConnectivityError`): `URLError` transient codes,
  `NSError` `NSURLErrorDomain`, and `AppError.aiServiceError` phrase match —
  `networkPhraseSet` includes `"offline"`, `"timed out"`, `"request timed out"`,
  `"could not connect"`, etc. **This already catches the `Kilo Code request timed
  out after 60s` final error.**
- On each retry it publishes `ProviderIssueStatusEvent(.networkOffline,
  cooldownUntil:)` → non-modal banner with live countdown.
- `AIChatPanel.providerIssueBanner`: network-offline renders **distinct blue** +
  `wifi.slash` icon, headline agnostic `"Network offline"` (no provider name quoted).
- `ConversationManager.providerIssueTypeLabel`: `.networkOffline` → "Network offline".
- Unit tests: `compassHarnessTests/NetworkRetryHarnessTests.swift` (3 tests pass).
- **Verification status:** `./run.sh build` green; `NetworkRetryHarnessTests` 3/3;
  `ToolLoopEngineRecoveryHarnessTests` 3/3; `ToolLoopDropout`/`ContinuationGuard`
  show only their known pre-existing unrelated failures.

> Note: this fixes S1 and *classifies* the S2 timeout as network-retryable, but S2's
> real damage was the S3/S4 thrash occupying the session — CAL (§4) is what prevents
> the thrash. Keep both.

---

## 7. Mode / plan-loss fix (S6)

**Symptom:** At 10:14 the model said *"I'm currently in chat mode, which is read-only…
no prior plan or task description came through (the earlier turn errored out)"* — the
network drop at 09:46/10:13 dropped mode + plan handoff.

**Design:**
- Audit `ConversationManager` recovery path + `TaskPlan` (`Services/Planning/TaskPlan.swift`)
  + `ConversationSendCoordinator` resume logic: after any error-recovery, re-inject
  into the resumed prompt: (a) current `AIMode` (chat/agentic), (b) the active
  `TaskPlan` steps + completed markers, (c) todos, (d) last assistant intent.
- Implement a **rehydration bundle** persisted to `.ide/` (session/plan JSON) and
  reloaded on recovery — same pattern as L5 compaction rehydration.
- Add a harness test replaying a mid-tool-loop network error and asserting the resumed
  request carries mode + plan context (no "I'm read-only" regression).
- **Files:** `ConversationManager.swift`, `TaskPlan.swift`,
  `ConversationSendCoordinator.swift`, `SystemPromptAssembler.swift` (inject mode/plan).

---

## 8. Implementation sequencing (phased) — actual delivered order

| Phase | Scope | Status | Size |
|---|---|---|---|
| **A** | L0 + L1 + L2 (truncation fix, recoverable offload, ranged reads) | ✅ IMPLEMENTED | M |
| **B** | L3 — LoopBreakController + single-message follow-up + BranchReviewNode simplification | ✅ IMPLEMENTED | L |
| **C** | L4 — Convergence detector (wall-clock + reads-without-write) | ✅ IMPLEMENTED | M |
| **D** | L5 — ContextTool session enrichment | ✅ IMPLEMENTED | M |
| **E** | L6 — Subagent context isolation | ⬜ Not started | L |
| **F** | L4 alt — Local MLX summarization | ⬜ Not started | M |
| **G** | L5 alt — Repo-map + compaction | ⬜ Not started | L |
| **H** | §7 Mode/plan-loss fix | ⬜ Not started | M |

**Verification harness:** convergence replay test (`testConvergenceDetectorFiresAfterExcessiveReadsWithoutMutation`) validates the convergence mechanism with a scripted harness. Full session replay against `03191936.ndjson` is the next validation step.

---

## 9. Test / verification strategy

- **Replay harness:** a `ContextAccessHarnessTests` that replays session 5124BEA4's
  recorded tool sequence against the *new* CAL and asserts:
  - distinct re-reads of any single file ≤ 2 (vs 36),
  - zero temp-file "view" hacks,
  - every overflow results in a disk-offload + actionable hint (telemetry marker),
  - final response delivered (no timeout surrender),
  - context-window usage stays < ~60% (no runaway).
- **Unit tests:** `MessageTruncationPolicy` (window-aware skip; recoverable offload
  preview/hint), `ReadFileTool` (range + `char_offset` + continuation footer),
  `ResearchSubagent` (isolated context; bounded summary; fan-out cap).
- **Regression:** keep `NetworkRetryHarnessTests` green; re-run
  `ToolLoopEngineRecoveryHarnessTests`, `ToolLoopDropoutHarnessTests`,
  `ToolLoopContinuationGuardHarnessTests` (last two have *known pre-existing*
  unrelated failures — `testRecoverySummaryWithIncompletePlanTriggersExecutionRecovery`
  = BranchReviewNode open item; do not conflate).
- **Telemetry assertions:** `.ide/logs` gain `context.offload` / `context.subagent`
  events so future sessions can be audited for re-read storms automatically.

---
## 10. Key files inventory (current state — A through D implemented)

**Phase A — Truncation & Ranged Reads (L0-L2):**

- `Services/CloudPipeline/MessageTruncationPolicy.swift` — added `ToolOutputArchive`
  (window-aware `effectiveToolOutputLimit`, `offload`)
- `Services/CloudPipeline/ToolLoopConstants.swift` — cap semantics
- `Services/CloudPipeline/ToolLoopHandler.swift` — trivially (follow-up truncation pass)
- `Services/OpenAICompatibleChatService.swift` — window-aware `truncateToolOutput`,
  threads `model` + `projectRoot` through mapping chain
- `Services/Tools/ReadFileTool.swift` — `char_offset`/`char_limit`, continuation footers,
  updated description

**Phase B — Loop-Break Controller & Single-Message Follow-Up (L3):**

- `Services/CloudPipeline/ToolLoopHandler.swift` — rewritten follow-up assembly
  (priority chain), added `LoopBreakController` + `FollowUpMessageAssembler` types,
  `readOnlyLoopToolNames` now includes `MutationTools.readOnlyNames`,
  `shouldInjectStepUpdateInstruction` no longer fires on fixed schedule
- `Services/ChatPromptBuilder.swift` — `shouldForceExecutionFollowup` reordered
  (work-performed > pending > completion)
- `Services/Orchestration/Nodes/BranchReviewNode.swift` — simplified routing,
  capped `indicatesUnfinished` re-entry at `maxNeedsWorkReentries`
- `Services/CloudPipeline/ToolLoopConstants.swift` — added `maxNeedsWorkReentries`

**Phase C — Convergence Detector (L4):**

- `Services/CloudPipeline/ToolLoopHandler.swift` — convergence tracking +
  wall-clock + reads-without-mutation stall checks
- `Services/CloudPipeline/ToolLoopConstants.swift` — `maxReadsWithoutMutation`,
  `maxToolLoopDuration`

**Phase D — ContextTool Enrichment (L5):**

- `Services/Tools/ContextTool.swift` — session orientation (plan progress + files read)
- `Services/Tools/ToolFileAccessLedger.swift` — added `readPaths(conversationId:)`

**Tests:**

- `compassHarnessTests/ToolLoopEngineRecoveryHarnessTests.swift` — added
  `testConvergenceDetectorFiresAfterExcessiveReadsWithoutMutation`

**Network (Phase 0 — previous work, do not redo):**

- `Services/AIInteractionCoordinator.swift` — network retry with escalation schedule
- `ProviderIssueStatusEvent.swift`, `ConversationManager.swift`, `AIChatPanel.swift`
- `compassHarnessTests/NetworkRetryHarnessTests.swift`
---

## 11. Risks / open questions

- **Subagent cost & latency:** add fan-out caps + `maxTurns`; prefer read-only,
  in-process subagents over network-spun ones. Avoid unattended fan-out
  (industry $8k–47k incidents).
- **Local summarizer quality:** calibrate the local MLX prompt for "distill compile
  errors"; fall back to L1 preview if the local model is unavailable (`USE_MOCK`/no
  local model).
- **Prefix-cache stability:** L1 hints / L5 repo-map must be injected *after* the
  stable system prefix (or as cache-breakpoint-separated blocks) so they don't
  scramble the cached prefix (the original reason auto-injection was removed).
- **`char_offset` for minified files:** line-based paging breaks on single-long-line
  JSON; add char-level paging as fallback.
- **Rehydration correctness:** L5/CAL re-reads must re-validate file mtime to avoid
  stale context.

---

## 12. Success metrics (definition of done)

- Tool calls for the todo-app UI task: **311 → < 50**.
- Distinct re-reads of any single source file: **36 → ≤ 2**.
- Temp-file "view" hack usage: **18 → 0**.
- Context-window usage across a full session: stable, **< ~70%** (no runaway).
- Final response **delivered** (no timeout surrender) + deliverable **verified**
  (e.g. `tsc`/smoke check), not just "worked until it crashed."
- Network drop → non-modal banner + auto-recover (already true per §6); no app crash.
- Mode/plan survive a mid-loop error (no "I'm read-only" regression).

---

*End of design document. Implementation starts at Phase A (L0+L1+L2). The network
work in §6 is complete and must not be redone.*
