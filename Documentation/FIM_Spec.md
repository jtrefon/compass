# FIM (Inline Completion) — Feature Specification

Status: **Canonical spec for the inline-completion feature.** Written to survive
cleanup: after any refactor, this document must be loadable to rebuild the
feature from scratch with full context. Every decision below is grounded in
measured data (see `Documentation/FIM_Benchmark.md`) or explicit product
direction from the maintainer.

---

## 1. Product vision

Inline completion ("FIM") is a **slim, fast, useful** single-line predictor
backed by a small local model (Qwen2.5-Coder-1.5B-Instruct-4bit, fixed —
no user model selection). It predicts the next line of code as you type and
renders it as a ghost suggestion. The model is a local, in-process MLX
inference; no network.

Core UX promise: **the suggestion is available ~1 keystroke after you stop
typing, and adapts to your typing speed.**

### 1.1 Design principles

1. **Output is always a single line.** The ghost shows exactly one line; Tab
   accepts one line. Multi-line variants are *separate suggestions*, never
   longer output. (Renderer contract: `CodeEditorTextView.firstLine(of:)`.)
2. **Input context is the variable.** Suggestion latency is dominated by the
   input window size (measured: ~25-30ms/100 chars of prefill). Window is
   narrow by default (+10/-10 lines target; production today: 1500ch prefix
   + 300ch suffix).
3. **FIM stays on the small model.** Multi-line / agentic-quality generation
   belongs to the 4B chat model (`LocalModelCatalog.chatModel`), not FIM.
   (Measured: 1.5B multi-line output quality is poor.)
4. **Quality-first, performance-second ordering** for tuning decisions, but
   only among changes that don't break the single-line premise.
5. **One live path.** The feature has exactly one runtime path; everything
   else is dead and must be deleted, not fixed (repo-wide rule).

## 2. Non-goals (explicit — do not build)

- Dropdown of N suggestions (measured: 3 sequential single-line predictions
  = 4.3s small / 6.3s mid / 8.7s large files — not interactive). May be
  revisited with the 4B model as an explicit user action.
- Multi-line completions from the 1.5B FIM model (quality beyond poor,
  measured).
- Per-keystroke re-prediction *without* KV-cache reuse (prefill recomputes;
  TTFT 221ms-2s per call).
- User-selectable FIM models (fixed model is a deliberate constraint —
  removes a whole class of landmines).
- Remote/cloud inline completion as a routing mode (cloud path exists today
  only as prompt-based legacy; the product ships local-only).
- Chat-template prompting for FIM (model is pretrained on the raw infill
  template; `FIMTokenBridge.applyChatTemplate` must keep throwing).

## 3. Use cases (end-to-end)

### UC-1 Typing pause → single-line suggestion
1. User opens/activates a file (model pre-warm on focus, see §5).
2. User types; after a debounce (~300ms pause; the cadence tracker adapts),
   the app requests a suggestion for the current cursor position.
3. Suggestion is rendered as ghost text at the cursor within the budget
   (measured warm: 221ms @+10/-10 window; 479ms @production window).
4. Ghost text streams in as tokens arrive ("fill up as we go").
5. User presses Tab → the first line of the suggestion is inserted.
6. Any other keypress → ghost dismissed; typed char consumes the suggestion
   head if it matches (accept-verify, no model call).

Acceptance: TTFT ≤ ~500ms for windows ≤ 1500ch; suggestion quality ≥
current benchmark baseline (exact-match 21-23/49 on the corpus); Tab inserts
exactly one line.

### UC-2 Fast typing (burst)
- Cadence tracker sees inter-keystroke < ~150ms → budget drops to 1-3 tokens
  per call (measured feasible: ~50-130ms per keystroke with KV reuse), so
  the ghost keeps pace with the cursor.
- If the suggestion head matches what the user typed, it is consumed
  deterministically — the model is only re-invoked on deviation or pause.

### UC-3 Slow typing / pause
- Pause > ~300ms → full budget: generate up to newline/EOS, stop at first
  newline (never ramble past line 1).

### UC-4 Large file, cursor deep in it
- Window is always +N/-N around the cursor (not the whole file) — prefill
  cost stays bounded (~221ms at 10 lines). The whole-page KV cache (if warm)
  makes per-keystroke deltas nearly free.

### UC-5 Model not installed
- No suggestions; feature reports "model not installed" once; never errors
  or falls back to cloud. (Benchmark suite skips likewise.)

### UC-6 Memory pressure / idle
- Model + KV cache unload after idle timeout or memory pressure (reuses
  `MLXInferenceLock` and the existing pressure-unload path); pre-warm on
  next focus.

## 4. Benchmark ground truth (2026-08-05)

Full methodology in `Documentation/FIM_Benchmark.md`. Canonical numbers:

| Metric | Value |
|---|---|
| Exact next-line match (49-site corpus, 12 langs) | 21-23/49 (43-47%) |
| First-token match | 29-32/49 (59-65%) |
| Strong languages | C, C++, Java |
| Weak languages | Swift, CSS, PHP, Perl |
| TTFT @+10/-10 lines (~400ch) | **221ms** |
| TTFT @production window (1500ch) | **479ms** |
| TTFT @30% / 60% / 90% file | 0.75s / 1.33s / 2.05s |
| Prefill slope | ~25-30ms per 100 chars (linear) |
| Decode | ~20-33ms/token (narrow window ~40-50 tok/s) |
| Cold model load | 1.2-1.9s TTFT, ~300MB RSS delta |
| Multi-line rate | 3/3 (model always writes past line 1 — must be cut) |
| Determinism (T=0.1) | byte-identical for short completions |
| repPen 1.2 | actively harmful (18/49) — never use |
| Dropdown (3 sequential, small file) | 4.3s — rejected |

Production params (final, measured-optimal): **temperature 0.1, topP 0.9,
repetitionPenalty 1.1, repetitionContextSize 20, maxTokens 64 (renderer
clamps to line 1 anyway), context window 4096, prefillStepSize 512.**

## 5. Target architecture (post-cleanup)

```
Typing → CadenceTracker (EMA of inter-keystroke intervals)
         ↓ adaptive budget (tokens-per-call: 1-3 fast, full on pause)
EditorSnapshot → LineCompletionContextAssembler (+10/-10 window)
         ↓
FIMInferenceService (actor, holds warm ModelContainer + [KVCache])
   ├─ pre-warm on file focus: load model, prefill page prefix into KV cache
   ├─ per keystroke: trim cache to common prefix, encode delta (suffix tail)
   │    └─ MLXLMCommon.generate(input:cache:parameters:context:)   [KV reuse]
   └─ generateStream → ghost text renders token-by-token
Renderer (CodeEditorTextView): show firstLine only; Tab accepts firstLine;
accept-verify consumes suggestion head on matching keystrokes.
```

Key pieces (existing or to build):
1. **KV reuse in FIMInferenceService** — ✅ DONE (2026-08-05). Mirrors
   `NativeMLXGenerator` (`resolveKVCache`, `trimPromptCache`, delta-token
   `LMInput` via `MLXLMCommon.generate(input:cache:parameters:context:)`).
   Per-keystroke TTFT measured **1333ms → ~170ms** (8x); byte-identical to
   fresh prefill (transparency-verified). Two hard-won correctness rules:
   (a) trim must be **offset-based** (`cache.offset - commonLen`), not
   prompt-token-based — the cache holds prompt + generated tokens; (b) reuse
   only while `newPromptLen <= cachedOffset` (rotating-cache arrays don't
   shrink on trim; longer prompts would clamp their prefill write).
2. **Cadence tracker + adaptive maxTokens** — ✅ DONE. `LineCompletionEngine`
   ladder: pause (≥300ms) → 64; 200-300ms → 16; 100-200ms → 8; burst → 4.
   Measured per-call cost at 4 tokens ≈ 200ms, 16 ≈ 350ms, 64 ≈ 900ms.
3. **Accept-verify head-consumption** — ✅ DONE (500ms window; consumes the
   longest matching head and publishes the remainder without a model call).
4. **Stop-at-newline** — ✅ already effective (engine breaks the stream at
   `\n`; `onTermination` cancels generation).
5. **Pre-warm on file focus** — ❌ NOT BUILT (next; needs an editor-focus hook
   + a prefill-only entry on FIMInferenceService).
6. **Streaming ghost** — already exists (`generateStream`).

## 6. Current implementation map (pre-cleanup)

Live path today:
```
Keystroke → TextViewRepresentable+InlineCompletion → LineCompletionEngine
  ├─ (deterministic path) LineCompletionContextAssembler → Ranker/Filter → ghost
  └─ (model path) CompletionInferenceService → AIServiceInlineCompletionProvider
        → FIMInferenceService (MLX, Qwen2.5-Coder-1.5B) → ghost
Renderer clamp: CodeEditorTextView.firstLine(of:) (display + Tab accept)
```

Files (all FIM-related; cleanup target):
- `Services/LocalModels/FIMInferenceService.swift` — core model service
- `Services/LocalPipeline/InlineCompletion/` — CompletionInferenceService,
  CompletionTelemetryService, CompletionTriggerPolicy, EditorSignalBridge,
  InlineCompletionDebugStore, InlineCompletionSettingsStore
- `Services/LocalPipeline/LineCompletion/` — LineCompletionContextAssembler,
  LineCompletionContextualFilter, LineCompletionEngine, LineCompletionRanker,
  LineCompletionResultCache
- `Core/Completion/InlineCompletionModels.swift` — types (request, settings,
  payload)
- `LocalModelCatalog.fimModel` / `LocalModelFileStore.fimModelDirectory`
- `Components/CodeEditorTextView.swift` (ghost), `TextViewRepresentable+InlineCompletion.swift`
- Tests: Completion*Tests, LineCompletion*Tests
- Harness: `CompassHarnessTests/FIMBenchmarkHarnessTests.swift`, `FIMBenchmarkFixtures.swift`
- run.sh: `fim-bench.conf` plumbing (§8)

## 7. Landmines discovered (cleanup checklist — verify each)

1. **Two provider init paths** in `AIServiceInlineCompletionProvider` (one
   takes `aiServiceProvider` + offline checker; the other takes remote/local
   providers + selection store) — remnant of the model-changer experiment.
   One should die.
2. **Hybrid routing modes return nil** (`CompletionInferenceService.swift`
   `case .hybridPreferLocal, .hybridPreferRemote: return nil`) — silently
   broken; product ships local-only anyway.
3. **Two prompt shapes**: prompt-based `complete(prompt:)` (with
   Language/File/Scope/Symbols — the cloud/legacy path) vs prefix/suffix FIM
   path. Only the FIM path is product.
4. **`maxSuggestionLength` default 120 + `multilineEnabled` true** — conflicts
   with the single-line premise; the renderer clamps, so the extra tokens are
   wasted latency (measured ~45% waste). Setting + defaults to reconcile.
5. **`FIMInferenceService` internals**: hardcoded `contextLength = 4096`,
   `kvBits: 0` no-op with comment, `FIMTokens.qwen25Coder` constants, legacy
   `bridge`/tokenizer plumbing — audit for dead members (several already
   deleted in the 2026-08 dead-code pass).
6. **`LineCompletionEngine`/Ranker/Filter** (deterministic path) — separate
   system from FIM; decide: is it the "typeahead string-match proxy" (keep,
   as accept-verify/instant path) or duplicate (merge)? Spec says: keep as
   the instant typeahead layer.
7. **Settings store knobs** (aggressiveness, retrievalEnabled, routingMode,
   multilineEnabled, maxSuggestionLength) — mostly experimental; reconcile
   with spec (keep: debounce, maxSuggestionLength; drop or repurpose rest).
8. **`CompletionTriggerPolicy` + `CompletionTelemetryService`** — verify they
   are on the live path or delete.
9. **UIStateManager `inlineCompletionMaxSuggestionLength`** — verify usage.
10. **FIM harness defaults** must mirror production defaults (already aligned
    at 0.1/0.9/1.1/64); the env path goes through `fim-bench.conf` — never
    reintroduce `TEST_RUNNER_ENV_`-only reading for app-hosted tests.
11. **`LocalModelSelectionStore`** — FIM model is fixed; any selection-store
    usage for FIM is dead.
12. **`EditorSignalBridge` / `InlineCompletionDebugStore`** — dev tooling;
    keep only if used by the live path.

## 8. Experiment protocol (how we tune safely)

1. Knobs flow via `COMPASS_FIM_*` env vars → run.sh writes `fim-bench.conf`
   in the harness test profile dir (app-hosted test processes cannot read
   env vars; verified 2026-08-05).
2. Every run: verify the config header line prints the intended values before
   trusting numbers (the 2026-08 "topP=1.0 champion" was a false positive
   from silently-defaulted configs).
3. Noise rules: sampling noise at T=0.1 is ±1-2 sites of 49 (~4%). Single-run
   deltas below that are noise; require structural signals (e.g. truncation
   counts) or 3-run confirmation before changing production defaults.
4. Defaults changes must be mirrored in BOTH `FIMInferenceService` and the
   harness `samplingConfig()`.

## 9. Decision log

| Date | Decision | Evidence |
|---|---|---|
| 2026-08-05 | Keep production sampling params (0.1/0.9/1.1/64) | Sweep: no config beat it beyond noise; repPen 1.2 regressed |
| 2026-08-05 | Reject maxTokens=128 | Gain within noise; output budget moot (renderer clamps line 1) |
| 2026-08-05 | Reject topP=1.0 "champion" | Env-propagation bug — false positive |
| 2026-08-05 | Reject dropdown (N sequential suggestions) | 4.3s+ for 3 suggestions; revisit with 4B model |
| 2026-08-05 | Keep FIM on 1.5B; multi-line on 4B only | 1.5B multi-line quality beyond poor |
| 2026-08-05 | KV reuse = the per-keystroke enabler | Research: supported in mlx-swift-lm; proven in NativeMLXGenerator |
| 2026-08-05 | Narrow window (+10/-10) is quality-safe | Ablation: 21-23 narrow vs 15-19 padded |
| 2026-08-05 | Adaptive budget ladder (4/8/16/64 by gap) | Measured per-call: 4t≈200ms, 16t≈350ms, 64t≈900ms |
| 2026-08-05 | KV trim must be offset-based; capacity guard | Both bugs caused silent quality drops (rambling) — caught by matrix A/B |

## 10. Open questions / next milestones

1. ✅ KV reuse in FIMInferenceService — done, benchmarked (per-keystroke TTFT
   ~170ms vs 1333ms; transparency + quality verified).
2. ✅ Adaptive token budget + accept-verify — done (engine ladder
   4/8/16/64 by typing gap; head-consumption without model calls).
3. Pre-warm on file focus (model load 1.2-1.9s + optional page prefill) —
   the remaining latency lever; needs an editor-focus hook and a prefill-only
   service entry.
4. Language weak-spot improvement: Swift/CSS/PHP/Perl (model training
   distribution; possibly prompt-window tuning, not sampling params).
5. Consider a 4B-model variant path for multi-line suggestions (rejected for
   FIM itself — spec §2).

