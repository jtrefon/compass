# Tooling Quality Rebuild — The Best Indexer, The Smallest Toolset, The Closed Planning Loop

> **Decision 2026-08-08:** No quick patches. We do it right or we don't do it at all.
> This doc is the single source of truth for the tooling rebuild. Previous audits
> (`agent-tooling-audit.md`, `full-application-review-2026-07-24.md`,
> `agentic-context-access-layer.md`) are inputs, not plans.

## 0. Executive choices

| Pillar | Previous suggestion (compromise) | **Chosen direction (quality)** | Why |
|---|---|---|---|
| **Indexed search** | Fix `lineEnd` via Brace/Indent (quick) then maybe tree-sitter | **Tree-sitter first, no intermediate regex fix** | Regex was the regression. `BraceAnalyzer`/`IndentLevelCalculator` are dead code precisely because regex can't carry scope. Ship surgery or don't ship it. |
| **Tooling** | Nuke vs surgical | **Nuke to 5+1 core, then rebuild curated pieces** | Graveyard (`ls`, `glob`, `exclude_from_index`, `pinned_rule_*`, `ToolAliasRegistry`, `MinimalToolset` flag, `isExploratoryCommand` guard) pays token + maintenance tax every turn. |
| **RAG** | Keep as-is | **Curated memories, not raw dump** | Ingesting every `ls` line into FAISS is why recall never helped. |
| **Planning** | Tool the model may call | **Control plane the runner drives** | `plan` as a model tool never converged. As runner state it bounds context to one `PlanItem` — thesis scales 2 → 5000 items. |

Performance and quality are the governors. No feature lands without a benchmark and a harness proving it.

---

## 1. The indexer — best in class, surgical `read` is the product

### Why we keep it (your thesis, validated)

* `grep → line` tells the model *where* but not *how much* to `read`. With the 12K `mapValidToolMessage` cap in `OpenAICompatibleChatService`, full-file reads are truncated → re-read storms (36× in audit) → temp-file hacks.
* A precise indexer gives `read(path, start_line, end_line)` for the *body* of a symbol — 1 tool call, fits context, no guessing.
* Brace languages (`Swift`, `JS`, `TS`, `PHP`) and indent languages (`Python`, `YAML`, `sh`) are **one** problem when the extractor walks an AST, two when it hand-rolls regex.

### Current failure (measured, not guessed)

* All 11 call sites in `SymbolExtractor.swift` set `lineEnd = lineNum` (`SwiftParser.swift:44` via `RegexLineSymbolParser:22` same). DB column `line_end` exists (`DatabaseSchemaManager.swift:44`) but is never real.
* `BraceAnalyzer` + `IndentLevelCalculator` ship but have **zero callers** from `SymbolExtractor`/`IndexerActor` — indent engine proved the design, then was bypassed.
* Dual schema: `symbols` (legacy `searchSymbolsWithPaths`) + `symbol_names/details/locations` (new) both written at `IndexerActor.swift:52` (`delete + insert + save` ×2). Waste + drift.
* Languages: only `swift/js/ts/py/php` in `SymbolExtractor.extract` switch. `CodeLanguage.yaml/sh` listed in enum but no parser — spec vs implementation gap.
* Regex `regexCache` (14 patterns) already patched for `actor`, `typealias`, `async def` ad-hoc — classic regex rot.

### Target architecture — tree-sitter

Reuse `Packages/SyntaxHighlighting` grammars already vendored for highlighting. No new native deps beyond the existing `libtree-sitter` linkage.

```
IndexerActor.indexFile(at: url)
  │
  ├─ LanguageModuleManager.grammar(for: ext)  // swift, js, ts, tsx, py, php, yaml, sh, go, etc.
  ├─ TreeSitterSymbolExtractor.extract(url, content, grammar)
  │    ├─ parse(content) → TSTree
  │    ├─ query("(class_declaration) @cls (function_declaration) @fn (method_definition) @mth
  │    │         (variable_declaration) @var (interface_declaration) @iface)")
  │    ├─ for each capture → symbol: name = node.child(named:"name").text
  │    │                     kind = captureName
  │    │                     lineStart = node.startPoint.row + 1
  │    │                     lineEnd   = node.endPoint.row + 1     // ← real scope, braces or indent solved by TS
  │    │                     scope/signature/parentName from child nodes
  │    └─ fallback: RegexLineSymbolParser only for unknown grammars (marked low-confidence)
  ├─ DatabaseStore.upsertResource + insertSymbols (single schema: symbol_names/details/locations)
  └─ FTS sidecar: optional per-file trigram for `searchIndexedText` or drop in favor of rg (see §1.4)
```

**Languages day-one:** `swift, js, jsx, mjs, ts, tsx, py, php, yaml, yml, sh, bash, zsh, json, markdown` (tree-sitter has stable grammars for all). Add `go, rust, kotlin` behind `LanguageModuleManager.availableLanguages`.

**Symbol kinds:** `class, struct, enum, protocol, extension, actor, function, method, initializer, property, typealias, variable` — mapped from `SymbolKind.swift` + `ExtractedSymbol.kind` (already stringly, will be enum-tightened).

**DB:** Single source of truth: `symbol_names/details/locations`. Delete legacy `symbols` table after `SearchProjectTool` migration. `line_end` becomes authoritative — harness asserts `lineEnd >= lineStart` and `lineEnd - lineStart` covers the brace/indent body.

### Performance & quality bars (must pass before merge)

| Metric | Bar | How measured |
|---|---|---|
| Index full project (5000 files, MacBook M1) | < 8s cold, < 300ms incremental (1 file change) | `IndexerActor` bench under `HarnessRuntime` with `.build/.git/vendor` excluded |
| Symbol precision | `lineStart`/`lineEnd` exact on fixture suite (Swift class with extension, Python nested `def`, YAML mapping) | Golden-file tests `Index/Parsing/*Fixtures.swift` — no regex, snapshot AST |
| `search` → `read` hit rate | ≥95% of `search` results yield a `read` that returns the full symbol body without follow-up `read` | Harness `PureAgenticHarnessTests` variant counting `read` calls per task |
| No dual writes | `IndexerActor` writes one schema only | `git diff` guard in CI |
| No `print` leaks, no `@unchecked Sendable` suppression on new code | `SwiftLint` + `AppLogger` only | CI lint |

### `search` tool contract after

```
search(query, offset, max_results)
  → [{file, line_start, line_end, kind, context, signature}] grouped by file
     (sorted relevance: exact symbol name > prefix > substring)
read(path, start_line=line_start, end_line=line_end)
  → exactly the body, paginated footer only if truncated
```

Delete `ls`/`glob` as discovery — `search` is discovery. Keep `rg` as fallback inside `search` for unindexed languages, not as a separate tool.

**Files that change:** `Compass/Services/Index/Parsing/*Parser.swift` (deleted → `TreeSitterSymbolExtractor.swift`), `Compass/Services/Index/SymbolExtractor.swift`, `Compass/Services/Index/Database/DatabaseSchemaManager.swift` (drop `symbols` DDL), `Compass/Services/Index/Indexing/IndexerActor.swift` (single insert), `Compass/Services/Tools/SearchProjectTool.swift` (new result shape), `Packages/SyntaxHighlighting` (grammar bumps, no new package).

---

## 2. Tooling — nuke to the nucleus, then curate

### Principle: macOS-native, CLI where it wins, native where safety wins

You said: heavily lean towards CLI tooling, keep web/index only if performant, otherwise file IO is enough. Decision: **lean CLI for discovery & execution, native for guarded mutation, curated native for search/precision.**

Nucleus (**5+1**) — the only tools on the default `coder` prompt:

| Tool | Mode | Why native vs CLI |
|---|---|---|
| `read` | native | `PathValidator` + `ToolFileAccessLedger` + ranged pagination (`start_line/end_line`, `char_offset/limit`) + envelope. `bash: cat` would bypass safety + serialization. |
| `edit` | native | `old_string/new_string` primary (no prior `read` required, unique-match guard, `replace_all`), line-range fallback. Hooks `PreWritePreventionEngine` + `ToolScheduler` per-path serialization. The one the audit proved must not require a roundtrip. |
| `write` | native (or folded into `edit(create:true)`) | Greenfield create. Shares `FileToolWriteApplier` with `edit`. Single write path. |
| `rm` | native (56 LOC) | Trivial but safety-gated delete. Could be `bash: trash` — keep native for the 56-line win and envelope audit. |
| `search` | native wrapper over `rg --json` + indexer ranges | LLM is bad at `rg` flags. Thin wrapper (`query → rg -n --no-heading` + `GlobMatcher`/`IndexFileEnumerator` exclusion + dedup + pagination) saves 2-3 model turns. Returns surgical `line_end` from §1 when available, `rg` line otherwise. |
| `bash` | native terminal | **The escape hatch.** Sessioned `start/wait/send_input/stop` in `TerminalTools.swift` (678 LOC justified — it's a terminal, not a tool). Project-root cwd, `RunCommandOutputBuffer` 64KB/32KB, no `isExploratoryCommand` guard. Covers `ls/re` (for listing), `fd`, `swift build`, `npm test`, `git`, linters, formatters — everything not covered above. |

**Nuked (deleted, not deprecated):** `ls` (`ListFilesTool`), `glob` (`FindFileTool`), `exclude_from_index` (`IndexExclusionTool` → static `.ide/index_exclude` + `IndexFileEnumerator` handles it), `pinned_rule_*` (3 tools → `.ide/pinned_rules.md` edited via `edit`), `context` raw dump (replaced by curated RAG below), `PlanTool` as model tool (moved to runner, §4), `ToolAliasRegistry` (after prompt sweep), `MinimalToolset` flag, `FileToolProposalStager` unless `mode: propose` is product, the `isExploratoryCommand` rejection branch.

**Kept separately, rebuilt for performance:**

* **Web:** Replace `WebKitSession` (478 LOC hidden `NSWindow` + `WKWebView`, 25s waits, per-session window leak that trips `HARNESS_MAX_RSS_GB=6`) with `URLSession + Readability (SwiftSoup)` fetch. Keep `web_search` (Google) as `URLSession` scraper, keep `web_fetch` as single `url → cleaned text` tool. Add `WKWebView` fallback only if `Content-Type` needs JS rendering (gated, not default).
* **Token budget:** 6 schemas × ~250 tokens ≈ 1.5K vs today ~10K (16 tools + `Prompts/Tools/v3/*.md` prose 3.9K). Frees context for project shape.

**Single sources of truth (enforced, not suggested):**

* `ToolTaxonomy` — only place listing `readOnly/mutation/terminal/planning`. Never hardcode names in filters.
* `ToolMarkupStripper` — only stripper.
* Prompt vs schema coherence — `Prompts/Tools/*.md` deleted as prose; schemas are authoritative. If prose is needed, codegen it from `parameters` at build time; `./run.sh check-prompts` fails CI on orphan.

**Files that change on nuke:** `Compass/Services/ConversationToolProvider.swift` (allTools list), `Compass/Services/AITool.swift` (kept but tightened via `ToolArgumentCoercion`), `Compass/Services/Tools/TerminalTools.swift` (delete guard), `Compass/Services/Tools/WebKitSession.swift`+`WebSessionStore.swift` (replaced), `Compass/Services/ToolAliasRegistry.swift` + `MinimalToolset.swift` + `ListFilesTool.swift`+`FindFileTool.swift`+`IndexExclusionTool.swift`+`PinnedRule*.swift` (deleted), `Compass/Models/AIMode.swift` + `ToolTaxonomy.swift` (pruned), `Compass/Services/SystemPromptAssembler.swift` + `Prompts/**` (pruned), `CompassHarnessTests/**` (tool-count assertions).

---

## 3. RAG — from dump to memories

### Thesis you named: accumulate project-specific knowledge so we don't re-discover it

Others call it "memories", you called it ingest conversations + collect experience. Today it ingests *everything* and helps *nothing* — because signal is drowned.

**Current:** `VectorStoreEmbeddingCoordinator` buffers `chat.user_message → chat.assistant_message` pairs + every `ToolResultEvent` output truncated to 500 chars, embeds via `MemoryEmbeddingGenerating` (hashing fallback unless CoreML loads), stores in FAISS `VectorStoreService` (`FAISSVectorIndex` + `VectorStoreMetadata` + `idMapping`) under `.ide/vector_store/`. `ContextTool` returns topK + `ToolFileAccessLedger` orientation. Cost: `libfaiss_full.a` + `CFAISSWrapper` + dimension fallback at `DependencyContainer:215` that once silently produced an empty store.

**Quality rebuild — curated, hierarchical, gated:**

1. **Ingest selectively.** Keep `ContextLogEvent` pairing. **Drop** `ToolResultEvent` for `ls/search/glob` noise. **Keep** only: `edit/write` diffs (files created/modified), `bash` *failures* + the fix (error string → edit that fixed it), `plan.finishTask` summaries (item done, how verified). One decision beats 20 tool spews.

2. **Summarize before embedding.** Don't embed raw 500-char truncation. Have `ChatHistoryCoordinator` summarize `query+response` into `decision: {file} changed because {reason}, verified by {test}` (≤80 tokens) then embed the summary. One vector per turn, not per tool.

3. **Hierarchical stores, filtered recall.** Split one flat FAISS into logical namespaces:
   * `project_knowledge` keyed by `projectRoot` — ingested summaries that survive sessions
   * `conversation_memory` keyed by `conversationId` — this session's Q/A pairs
   * `repair_patterns` keyed by error signature — `bash` errors → fix pairs
   `ContextTool` queries `project_knowledge` first (prior sessions matter), fallback to `conversation_memory`. This is how the agent "skips re-discovery" — next session auto-loads prior decisions without re-reading the codebase.

4. **Gate the heavy dep.** `COMPASS_ENABLE_RAG=1` loads `VectorStoreService`; default gives `ContextTool` → orientation (`plan` progress + `readPaths` ledger) only. Fast startup stays fast; FAISS only when recall is product-critical. When enabled, startup uses the existing `withTimeout(15)` path — no silent empty store.

**High-ROI RAG uses beyond "recall conversation" (your ask for ideas):**

* **Error → fix retrieval.** `bash` exit non-zero + stderr → embed error; next time `context("stderr: EADDRINUSE")` returns the `edit` that fixed it. Directly cuts recovery loops.
* **Requirement → file mapping.** Embed `TaskPlan.items[].description/purpose` + files touched; future `plan init` proposes tasks conditioned on prior similar goals without re-indexing.
* **Decision log.** Embed approved `pinned_rules.md` deltas + review verdicts (`LeafReviewNode` would use it for `LEAF_FAIL` history). Subsequent `LEAF_FAIL` retries get the prior correction context.
* *Not* for symbol search — that's the indexer (§1). Keep them orthogonal.

**Files that change:** `Compass/Services/VectorStore/VectorStoreEmbeddingCoordinator.swift` (filter ingestion), `Compass/Services/VectorStore/VectorStore+ConversationRAG.swift` (summarize path), `Compass/Services/VectorStore/VectorStoreService.swift` (namespace support, gate), `Compass/Services/ConversationToolProvider.swift` (wire `context` only when gated), `Compass/Services/DependencyContainer.swift:215` (remove dimension fallback, assert).

---

## 4. Planning — the closed small loop you described

### Thesis you named, validated

> Complex tasks broken down, planning tool feeds them so small-context agent doesn't worry; this could be the graph-like solution to agentic loop issues — the agent closed in a small pre-defined loop of its own creation, fed current context at the right time (when completion flagged), allowing 2–5000 item orchestration if it works.

That is correct. The failure was not the idea — it was exposing `plan` as a model-choice tool.

**Current:** `PlanTool.swift` `action: init → finishTask → finishTask …` with `raiseQuestion/breakOutCantContinue`, persisting `TaskPlan` (`id, goal, value, domain: architecture/implementation/research/refactor/analysis/design/investigation, mode, items: PlanItem{description,purpose,context,doneCriteria,status}, currentIndex`) via `ConversationPlanStore` dual JSON+legacy markdown + `PlanChecklistTracker` deprecated cache-5 LRU. Execution `finishTask` marks current done + `activateNextPending()` but the loop never enforces "one item's tools visible". `Orchestration` graph (`Researcher/Analyst/Architect/PM/LeafExecutor` → `PipelineProcessor:3` no-ops) has no consumer for `TaskPlan` — plan is a tool without a runtime, so harness `LocalMultiTurnHarnessTests` never calls `plan(init)`.

**Quality rebuild — plan as control plane, not as tool**

The runner drives `plan`, not the model. Model never sees `plan` during execution; it sees only the current `PlanItem`'s context, fed at completion.

```
OrchestrationGraphRunner (exists, currently pm→leaf cycle)
  │
  ├─ load TaskPlan for conversationId
  │    ├─ from PlanTool.init (model proposes, framework validates shape)
  │    └─ or from ResearcherNode auto-generated (2-phase: research → plan)
  ├─ for each PlanItem in order:
  │    ConversationSendCoordinator.executeLocalModelToolLoop
  │      • SystemPrompt = mode-coder + injected:
  │          "Task N/M: {description}\nPurpose: {purpose}\nContext: {context}\nDoneWhen: {doneCriteria}"
  │        + ONLY this item's files in context (not the 5000-item backlog)
  │      • Tools = nucleus 5+1 (no plan). Budget ≤8 tool calls per item.
  │      • On finish → runner auto-calls ConversationPlanStore.setPlan(completeItem(N, summary))
  │        and activates N+1, injecting its context. Model never sees the switch.
  │      • On failure → leafCorrectionContext + one retry, else blocked
  └─ FinalResponse node only when TaskPlan.isComplete → ToolMarkupStripper → ChatHistoryCoordinator.append
```

*Why this fixes context + loop issues:* each micro-loop is **1-item big**. A 5000-item refactor carries a 200-token system prompt, not a 5000-line plan. The agent can't over-engineer past the item's `doneCriteria`. Research/refactor orchestration becomes "many small loops" instead of "one giant loop that drifts".

* **Delete `plan` from `allTools` as a model tool** after the runner owns it. `PlanTool` remains as a framework entrypoint for `init` (research phase) and for manual `breakOutCantContinue` — not for `finishTask` during execution.
* Remove `PlanChecklistTracker` + markdown `cache: [String:String]` — single `TaskPlan` JSON per conversation, no LRU.
* `PlanItem.doneCriteria` becomes the verification hook harness checks (not "model said LEAF_FAIL").

**Files that change:** `Compass/Services/Planning/PlanTool.swift` (strip execution `finishTask` for model, keep `init/breakOut`), `Compass/Services/Planning/TaskPlan.swift` (tighten `domain` enum use, add `verificationLog`), `Compass/Services/Planning/ConversationPlanStore.swift` (drop legacy string API, keep JSON), `Compass/Services/CloudPipeline/*` + `Compass/Services/Orchestration/Graph/*` (runner per-item loop, retire `PipelineProcessor` no-ops), `Compass/Services/ConversationSendCoordinator.swift` (per-item context injection), `Compass/Services/SystemPromptAssembler.swift` (append item context).

---

## 5. Sequenced execution (quality-gated, not time-boxed)

No item merges without its bar. Quick patch rejected at plan level.

| Phase | Ships | Gates (must be green) |
|---|---|---|
| **1 — Indexer (highest leverage)** | Tree-sitter extractor, single-schema DB, `search` returns surgical ranges | Fixture suite `swift/py/yaml/sh` exact `lineEnd` + 5000-file cold <8s + `search→read` ≥95% single-call hit + no dual writes |
| **2 — Tool nucleus** | `ls/glob/exclude/pinned/alias/minimal` deleted, `isExploratoryCommand` guard gone, `read/edit/write/rm + rg-search + bash` nucleus, `URLSession` fetch replaces `WebKitSession` | `./run.sh build` links without `libfaiss` when RAG gated off + `./run.sh check-prompts` 0 orphans + `harness-offline PureAgenticHarnessTests` no `NSWindow` leak + RSS <6GB |
| **3 — Planning as loop** | Runner drives `TaskPlan` per-item, `plan` removed from model toolset, `PlanChecklistTracker` deleted | Harness 300-item synthetic plan completes with one-item context injection per turn, no full-history re-issue, `LEAF_FAIL` recovery 1× then blocked |
| **4 — RAG curation** | Selective ingestion + summarization + hierarchical namespaces, `COMPASS_ENABLE_RAG` gate, dimension assert not fallback | RAG adds ≥2 fewer re-reads per repeat task vs baseline (`benchmark-local` KPI), `store.load` never silently empty |
| **5 — Hardening** | `ToolTaxonomy` + `ToolMarkupStripper` + `PathValidator` remain single sources of truth; `AITool.parameters` tightened via `ToolArgumentCoercion`; `print` banned via lint | `swiftlint/hardcoded_corner_radius`-style lint for `print` + `cornerRadius` + tool-name hardcoding all green |

Each phase ends with `bench + harness` before the next begins. No carry-over debt across phases.

---

## 6. Verification after every phase

```
./run.sh build                              # no libfaiss / tree-sitter link errors
./run.sh check-prompts                      # 0 orphans, no dead Tools/v2/*.md
./run.sh test SuiteName                     # IndexerPrecisionTests, ToolNucleusTests, PlanLoopTests
./run.sh harness-offline PureAgenticHarnessTests  # file exists, no markup leak, envelope status
./run.sh benchmark-local                    # tool-call count halved on fixture task (79 → <20 for WordPress review)
```

---

## 7. What is intentionally *not* done

* No `rg`-only index. Surgical `lineEnd` is the product — `rg` is fallback inside `search`, not the index.
* No new package for FAISS. FAISS lives behind the RAG gate; default path has no native `lib`.
* No `quick fix` branch for `lineEnd`. The regex path is deleted, not patched. If tree-sitter grammar for a language is not ready, that language returns low-confidence regex result *marked* as such until the grammar ships — never silently exact.

---

*Owner:* engineering (indexer + tooling + loop). *This doc is the decision record.* Update it in-place when a phase lands; don't fork a new plan.
