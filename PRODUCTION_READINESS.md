> **STATUS UPDATE (2026-08-01):** All four BLOCKERs and the P2 high set are FIXED
> (commits a349bf23..HEAD): blind-loop tool results, reachable timeouts, RAG
> retention + persistence, dim validation + error surfacing, Stop semantics,
> leaf-review bounds, plan-driven PM node, MLX memory pressure/serialization/
> KV reuse/unload, stats polling, grep -F + custom excludes, atomic persistence,
> liquid glass rollout, chat-bubble tokens. Remaining backlog: the MEDIUM table
> below plus SwiftLint sweep — see REVIEW_TRACKER.md.

# Production Readiness Report — Compass 0.6.1

Full top-down review of the agentic loop, tooling, tool-call parsing, FIM, local MLX
inference, RAG/vector store, codebase index, and UI/liquid-glass adherence.
Date: 2026-08-01. Every finding verified against the working tree.

**Overall status: NOT PRODUCTION READY.** The happy paths work and the test suite is
green, but four BLOCKERs make the core product behave incorrectly in real use:
the cloud agentic loop is blind (tool results dropped), tool timeouts can silently
never fire, and the RAG "memory" system is a startup snapshot that is never
persisted and never continuously ingested. The UI is a solid 6.5/10 on the design
token system with a real liquid-glass gap.

---

## BLOCKERS — must fix before any user-facing release

### 1. Cloud agentic loop is blind: tool results are dropped from every subsequent request
`OpenAICompatibleChatService.swift:436-438` + `ResearcherNode.swift:41-47` (same in
Analyst/Architect/LeafExecutor).

`buildValidToolCallIds` derives the valid set **only from committed assistant
messages that carry `toolCalls`** — but the graph nodes append only the tool-result
messages to history, never the assistant tool-call message. Every later request
therefore has an empty valid set and `mapValidToolMessage` returns `nil` for every
tool result. The researcher's multi-visit loop, architect/PM/leaf nodes, the
leaf-review QA call, and all multi-turn follow-ups execute **blind** in cloud mode.
The local-model path is unaffected (keeps `.tool` messages), which is why harnesses
(which assert file outcomes, not conversation content) pass.

**Fix:** mirror `ResearchSubagent.swift:83` — each node commits the assistant
response (with `toolCalls`) before its results.

### 2. Tool timeout enforcement has a race that can disable it entirely; timeouts surface as "user cancelled"
`AIToolExecutor+Timeout.swift:188-212` + `ToolExecutionSupport.swift:266-274`.

(a) The watchdog checks `isCancelled` before `remaining <= 0`, so
`ToolExecutionTimedOutError` (with its recovery guidance) is **unreachable** — every
timeout is mislabeled as a user cancellation.
(b) `updateCountdown` **removes the entry** when the deadline passes; if the watchdog
polls after that removal it sees `isCancelled == false, remaining == nil` and spins
forever — a hung `bash`/`npm install` is never killed.
(c) Consequence: the circuit breaker (`record` only fires on `TimedOutError`) is
inert.

**Fix:** drive the watchdog from a stored deadline; never remove on expiry (only on
finish/cancel); throw `TimedOutError` on deadline-pass.

### 3. RAG "memory" is a startup snapshot: continuous ingestion never runs and nothing added is persisted
`DependencyContainer.swift:251-257` + `VectorStoreService.save()` call sites.

(a) `VectorStoreEmbeddingCoordinator` is a **local `let`** in
`initializeHeavyServices` — nothing retains it, so it deallocates when the function
returns, its subscriptions cancel, and user-message/response/tool-result embedding
**never runs during a session**.
(b) `save()` (index + metadata + id-mapping) is called only after startup
`ingestConversations` and in `rebuildVectorStore`. Even with (a) fixed, every
in-session addition would vanish on quit.

**Fix:** retain the coordinator on `DependencyContainer`; persist on a debounce
after writes and on terminate.

### 4. RAG silently dies on embedding-model/dimension drift — no signal anywhere
`MemoryEmbeddingGeneratorFactory.swift:8-25` + `VectorStoreConfiguration.swift:11`
+ `FAISSVectorIndex.swift`.

The FAISS index is always created with `dimensions: 384`. `makeBestAvailable()`
prefers bge-small (384) but **silently falls back** to bge-base/nomic (768) or
bge-large (1024) if bge-small fails to load; the generator's real output dim is
computed but never validated against the index, and `ContextTool` wraps every
failure in `try?` → "No relevant context found". Result: dimension mismatch =
permanently empty RAG with zero diagnostics.

**Fix:** assert `generator.dim == index dim` at creation; create the index from the
generator's dim; surface `status: error` from ContextTool instead of empty-success.

---

## HIGH — must fix for the 0.7 cycle

### Agentic loop / tooling
| # | Finding | Location |
|---|---|---|
| H1 | `stopGeneration()` **clears** `cancelledToolCallIds` (wiping the very ids the executor checks); the execution loop never checks `Task.isCancelled` → Stop doesn't stop in-flight/queued tools, and per-call cancel is pre-execution only. | `ConversationManager.swift:950-964`, `ToolExecutionSupport.swift:307-344` |
| H2 | Leaf-review rework is blind + unbounded: verdict = `content.contains("LEAF_FAIL")`, `leafCorrectionContext` is write-only (never read), review response never committed, no per-node visit cap (only the global 64-transition budget). | `ResearcherNode.swift:192-201`, `OrchestrationState.swift:148` |
| H3 | `ProjectManagerNode` hardcodes "3 plan items" (`currentPlanItemIndex >= 3`); `taskPlan` is never populated by any node — build runs always execute exactly 3 leaves regardless of task scope. | `ResearcherNode.swift:139-142` |
| H4 | Stale cancelled task's catch sets `isSending = false` unconditionally (only the `defer` checks `activeRunCounter`) → a Stop→re-send race allows concurrent sends + preview clobber. | `ConversationManager.swift:826-830` |
| H5 | Timeout/cancel never kills the underlying process: `RunCommandTool`'s observe loop never checks `Task.isCancelled` — a hung command keeps running up to `wait_seconds+5`. | `TerminalTools.swift:324-336` |
| H6 | `RequestClassifier`: fast-path signals shadow mutation signals ("how do I fix the build error…" → `.fast` with `tools: []`); default is read-only `.review` (no bash). | `RequestClassifier.swift:25-38` |
| H7 | `SearchProjectTool` grep fallback reads whole files with no size/binary cap; grep results return absolute paths vs relative index results — the model can't rely on either. | `SearchProjectTool.swift:147-177` |

### Local inference (MLX) / FIM
| # | Finding | Location |
|---|---|---|
| H8 | Memory-pressure unload is dead code on macOS (`NSMemoryWarningNotification` never posts on macOS; should be `DispatchSource.makeMemoryPressureSource`), and FIM's separate container is never unloaded even when the handler fires. 4-6GB pinned on 8GB Macs. | `MemoryPressureObserver.swift:14-22`, `FIMInferenceService.swift:50-58` |
| H9 | FIM + chat run on **separate containers with no serialization**; the chat RSS guard measures whole-process RSS (includes FIM weights) → a concurrent FIM run can kill chat generation mid-stream. | `FIMInferenceService.swift`, `NativeMLXGenerator.swift:633-640` |
| H10 | KV-cache reuse **double-prefills** when the new prompt equals/prefixes the cached ids (reachable via the retry path with `preservesCache=true`) — the prompt is attended twice, generation continues from the stale answer. | `NativeMLXGenerator.swift:321-328` |
| H11 | KV-cache reuse **drops image/video inputs** (reused input is text-only) — Qwen3.5 is multimodal. | `NativeMLXGenerator.swift:322-325` |
| H12 | Any mid-stream error — including **user Stop** — calls `unloadModel`, dropping the container and all prompt caches: pressing Stop costs a full ~2.5GB reload + loses KV reuse for every conversation. | `NativeMLXGenerator.swift:150-153` |

### RAG / index / search
| # | Finding | Location |
|---|---|---|
| H13 | `getStats()` still walks the entire project **twice every 2 seconds** (status-bar poll), forever, in `.common` runloop mode. | `IndexStatusBarViewModel.swift:291-320`, `CodebaseIndex+Stats.swift:16-24` |
| H14 | `searchIndexedText` grep: query treated as **regex** (no `-F`; literal `a.b` matches `aXb`, `foo[` errors), hardcoded exclude dirs (ignores agent-maintained `.ide/index_exclude`), full-project scan per call. | `CodebaseIndex+TextSearch.swift:23-70` |
| H15 | Vector-store persistence is 3 non-atomic files; a crash between `metadata.save()` and `persistIDMappings()` corrupts the id mapping → plausible-looking but **wrong** retrieval after restart. | `VectorStoreService.swift:83-96,274-306` |
| H16 | `budgetMessages` (local loop) can split tool-call/tool-result pairs or drop the newest tool result under budget pressure → the model re-issues executed calls. | `LocalModelPromptBuilder.swift:179-189` |
| H17 | Prompt-cache eviction is `dict.keys.first` (hash order, not LRU) and keyed by conversationId only (not model) — active conversations evicted while stale ones stay; cross-model reuse hazard. | `NativeMLXGenerator.swift:192-199` |

### UI / liquid glass
| # | Finding | Location |
|---|---|---|
| H18 | `NativeTerminalView` leaks a subscription per appearance (`_ = eventBus.subscribe(...)`, no `.onDisappear`) — after N toggles one Clear click fires N times. | `NativeTerminalView.swift:34-38` |
| H19 | `nativeGlassBackground`/`NativeGlassSurface` is hand-rolled `ShapeStyle` **materials**, not the macOS 26 `glassEffect` API — only 7 call sites use true liquid glass; the window/panels/sidebar/settings render classic vibrancy next to liquid-glass pills. | `GlassStyle.swift:11-47` |
| H20 | Chat message bubbles (the most-rendered view) bypass the token system entirely: hardcoded 12/8 padding, custom `RoundedCorner` shape duplicating `UnevenRoundedRectangle`, raw `Color.accentColor`/`.secondarySystemFill`/`.white`. | `MessageContentCoordinator.swift:70-106`, `MessageUIComponents.swift:32-141` |

---

## MEDIUM — backlog for 0.7/0.8 (top 15 of ~40)

- **Agentic:** stage-based tool filtering strips `plan`, `pinned_rule_*`, `exclude_from_index` from tool-loop requests (prompts advertise them) — `ConversationPolicy.swift:14-16,59-61`; two divergent planning systems (PlanTool vs hardcoded PM loop); abandoned `run_command` background sessions never reaped; XML parser lacks self-closing form; entity decode order-nondeterministic + no numeric entities; WebKitSession `deinit` main-thread deadlock + session leak; countdown tick never stops when idle; empty final content commits an empty assistant message.
- **MLX/FIM:** FIM `kvBits: 4` is a no-op (RotatingKVCache not quantized); `toolCallFormat` silently discarded at container load (works by accident via `infer`); thinking markers not stripped from final output; reasoning streamed as content, never `LocalModelStreamingReasoningChunkEvent`; `LineCompletionResultCache` unbounded; RSS guard default (10GB) exceeds typical hardware and throws mid-stream instead of degrading; tokenizer cache not invalidated on model switch; download cancellation not propagated; `PromptPrefixCache` is a no-op with a prefix-collision invalidation bug.
- **RAG/index:** tool-layer file exclusion ignores agent-maintained custom patterns; `rebuildVectorStore` wipes and no-ops silently when no embedder exists; startup conversation ingestion is unbounded/sequential and marks missing conversations ingested; non-symbol-extractable files counted as "needing work" → spurious indexing events every open; SearchProjectTool pagination is dead-end (offset never yields pages); FTS5 dropped but docs/prompts still advertise it; `LIKE '%q%'` symbol scans; ContextTool same/prior-session label reads a never-set field; bge mean-pooling without query prefix hurts retrieval quality.
- **UI:** status bar raw colors + 24px height + magic widths; FileExplorer raw colors + magic minWidth; InlineAIPopover hand-rolls glass; status-color palette missing from tokens (green/orange/red hand-rolled in 3+ files); settings widths half-tokenized; EditorTabBar spacing/divider/font violations; NewProjectDialog hardcoded 400×250; chat close button has no a11y label; two pill-tab implementations diverging; ready-marker visible to VoiceOver; typing indicator re-renders 10 fps; duplicated focus-border code.

---

## Verified good (no action)

- ToolResultEvent telemetry is exactly-once per phase; NDJSON writes are single-path.
- Parser registry ordering is deterministic; HTML entities fixed for the common set; minimax/legacy/XML-paired forms recover correctly.
- Draft-commit flow, cancellation box, sendMessage re-entrancy guard, PathValidator sandboxing, keychain storage, SQLite transient binds, indexer dedupe, hybrid exclusion list + round-trip test.
- KV-cache `trim` direction is correct (verified against vendored mlx-swift); Qwen3.5 4-bit KV quantization genuinely active for chat; chunk publishing (1st + every 8th) correct.
- Embedding-dimension consistency on the **happy path** (bge-small=384 matches the index).
- Accessibility: AccessibilityID used widely, comprehensive keyboard shortcuts, no editor coordinator leaks found.
- Design tokens are real and widely adopted; literal `cornerRadius:` guardrail is clean.

---

## Roadmap to production readiness

| Phase | Scope | Est. |
|---|---|---|
| **P1 — release blockers** | B1 tool-result commit in nodes; B2 timeout watchdog/deadline; B3 RAG coordinator retention + persistence; B4 dim validation + ContextTool error surfacing | 2-3 days |
| **P2 — correctness highs** | H1 Stop semantics; H2-H5 loop/verdict/plan/re-entrancy; H6 classifier; H8-H12 MLX (memory pressure, container serialization, KV prefix reuse, media, unload-on-cancel); H13-H17 index/RAG perf+persistence; H18-H20 UI | 1-2 weeks |
| **P3 — polish** | MEDIUM backlog: ~40 items across tooling, inference, RAG, UI tokens/liquid-glass rollout | 2-3 weeks |
| **P4 — hardening** | Offline RAG harness test; FTS5 or documented scan bound; liquid-glass full-surface migration; status-color token palette; SwiftLint sweep | ongoing |

**Gate for 0.6.1 (current release candidate):** P1 blockers #1-#3 are user-visible
correctness bugs in the primary (cloud/coder) path. Recommend fixing P1 before
tagging `v0.6.1`; P2-P4 are 0.7+.
