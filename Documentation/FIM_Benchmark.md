# FIM Benchmark — Qwen2.5-Coder-1.5B-Instruct-4bit (local inline completion)

Measured with `CompassHarnessTests/FIMBenchmarkHarnessTests` against the
fixed FIM model (`LocalModelCatalog.fimModel`, 4096-token window hardcoded in
`FIMInferenceService`). Local model only — never runs in CI.

## Product premise (read this first)

- **Output is always a single line.** The renderer already clamps to the
  first line (`CodeEditorTextView.firstLine(of:)` — ghost display and Tab
  accept both use it). Multi-line variants are *separate suggestions*, not
  longer output.
- **Input context is what grows with file size** (small/mid/large = 30/60/90%
  of the 4096-token window).
- The useful KPI for a suggestion is therefore **TTFT** (time until line 1
  arrives) — anything generated after line 1 is discarded by the renderer.

## What the token numbers mean

Tokens ≈ 3.5 chars of code. `maxTokens` is the output ceiling: 64 tokens ≈
220 chars ≈ 2-4 lines; 128 ≈ 440 chars ≈ 5-10 lines. Production's effective
budget is `maxSuggestionLength` (default **120 tokens**, `multilineEnabled`
default true — the caller overrides the service default).

## Metrics

- **Quality (matrix)**: exact next-line match, line-sequence match,
  first-token match, normalized edit similarity, brace-balance validity
  (C-family), truncation flag.
- **Performance**: TTFT, total time, output length, first-line length,
  multi-line rate (how often the model writes past line 1 — wasted work),
  RSS before/after load, repeatability (determinism).
- **Corpus**: 49 mask-and-fill sites across 12 languages, sanity-checked
  (no leaked answers, brace-balanced fixtures).
- **Noise caveat**: sampling at T=0.1 is ±1-2 sites of 49 (~2-4%); single-run
  deltas below that are noise.

## Quality (production defaults: T=0.1, topP=0.9, repPen=1.1, maxTok=64)

Latest run: **23/49 exact (47%), 30/49 first-token (61%)**, sim 0.103.
Multi-run range across defaults: 21-23 exact (noise band).

| Language | n | exact | firstTok | sim | note |
|---|---|---|---|---|---|
| C | 4 | 3 | 3 | 0.88 | strong |
| C++ | 4 | 3 | 3 | 0.16-0.34 | strong exact, weak sim |
| Java | 4 | 3 | 3 | 0.92-0.94 | strong |
| C# | 4 | 2 | 3 | 0.35 | |
| HTML | 4 | 2 | 2 | 0.89 | |
| TypeScript | 4 | 2 | 3 | 0.66 | |
| JavaScript | 5 | 2 | 4 | 0.53 | |
| Rust | 4 | 2 | 2 | −0.29 | |
| Swift | 5 | 1-2 | 3 | 0.03-0.45 | weak (Qwen2.5-Coder is JS/Python/C++-heavy) |
| CSS | 4 | 1 | 1-2 | 0.09-0.29 | weak |
| PHP | 4 | 1 | 1 | 0.03-0.08 | weak |
| Perl | 3 | 0-1 | 1-2 | −0.13-0.21 | weakest |
| **TOTAL** | **49** | **21-24 (43-49%)** | **29-32 (59-65%)** | 0.09-0.11 | |

Brace balance holds for all C-family hits (structural validity).

### Hyperparameter sweep (matrix only; env-controlled via fim-bench.conf)

| Config | exact | capped | verdict |
|---|---|---|---|
| baseline 0.1/0.9/1.1/64 | 22 | 5-6 | production |
| 0.1/0.9/1.1/128 | 24, 23, 22 | 1-2 | no quality gain within noise — and output length is moot (renderer clamps to line 1). **Not adopted.** |
| greedy 0.0 | 22 | 5 | equal quality |
| 0.1/1.0/1.1/64 | 22 | 5 | neutral |
| 0.2 / 0.5 temps | 21-22 | 4-5 | neutral or worse |
| 0.1/0.9/**1.2**/64 | **18** | 3 | **repPen=1.2 actively harmful — avoid** |

Historical note: an earlier "topP=1.0 champion" was a false positive — the
sweep's env vars never reached the app-hosted test process, so every config
ran at defaults and the spread was pure noise. Knobs now flow via
`fim-bench.conf` (run.sh writes it; the suite verifies the header line).

**Tuning verdict: production defaults are already the sweet spot.** No
sampling-parameter change improves single-line quality beyond noise.

## Performance — file sizes (single-line premise, production defaults)

Medians of 3. Machine: Apple Silicon, macOS 26, model from disk (4-bit).

| File size (input context) | TTFT (line 1 ready) | Total | firstLine | multi-line rate |
|---|---|---|---|---|
| small (30%, ~2.5k chars) | **0.67s** | 1.4s | 27ch | 3/3 |
| mid (60%, ~4.9k chars) | **1.3s** | 2.1s | 14ch | 3/3 |
| large (90%, ~7.4k chars) | **1.95s** | 2.9s | 38ch | 3/3 |

Cold load (model from disk): 1.2-1.9s TTFT, RSS ~250-300MB after load
(process baseline ~110-260MB).

**Key finding — the model always writes past line 1 (multi-line 3/3):**
~45% of generation time produces lines 2+ that the renderer discards.
**Stopping generation at the first newline would make suggestion time equal
to TTFT** (0.67s / 1.3s / 1.95s) — a ~45% latency cut with zero quality loss
for single-line UX.

## Context-window sweep (the latency curve)

TTFT vs input window size — median of 3, suffix fixed at 300 chars.

| Window | TTFT | Total | firstLine |
|---|---|---|---|
| +10/-10 lines (~400ch) | **221ms** | 982ms | 42ch |
| +20/-20 lines (~800ch) | 340ms | 1089ms | 27ch |
| production window (1500ch) | 479ms | 1248ms | 16ch |
| small file 30% (~2458ch) | 752ms | 1494ms | 26ch |
| mid file 60% (~4915ch) | 1333ms | 2105ms | 14ch |
| large file 90% (~7373ch) | 2048ms | 2783ms | 38ch |

- **TTFT is linear: ~25-30ms per 100 chars** (≈0.26ms/char prefill slope).
- **Incremental-prefill proxy**: with KV-cache reuse, a keystroke's delta
  (~10 chars) would cost ~2.5-3ms of prefill — this is the per-keystroke
  prediction enabler.

## Quality vs window size (ablation)

Same 49-site corpus padded with balanced synthetic context:

| Window | exact | lines | firstTok |
|---|---|---|---|
| narrow (as-is, ~50-400ch sites) | 21-23/49 | 21-23 | 29-31 |
| padded to 1500ch | 15/49 | 16 | 26 |
| padded to 4000ch | 19/49 | 20 | 28 |

**Narrow windows do not cost quality** — more (unrelated) context slightly
hurts. The +10/-10 strategy is quality-safe. Caveat: filler is synthetic
Swift-like code regardless of fixture language; the direction is consistent
with FIM training behavior (local-context conditioning).

## KV-cache reuse — researched (2026-08-05)

**Supported by the vendored mlx-swift-lm (v0.6.0-227-gaa589b75) and already
implemented in this app** for the chat model (`NativeMLXGenerator.swift` —
`resolveKVCache`, `trimPromptCache`, delta-token inputs via
`MLXLMCommon.generate(input:cache:parameters:context:)`).

- `ModelContainer.generate` (what `FIMInferenceService` uses today) creates a
  **fresh cache per call** — full re-encode every keystroke.
- The cache-taking API: `MLXLMCommon.generate(input:cache:parameters:context:)`
  via `container.perform` (`Vendor/mlx-swift-lm/Libraries/MLXLMCommon/Evaluate.swift:1377`).
- `KVCache` classes are mutated in place and survive between calls; trim to
  common prefix with `trimPromptCache`/`cache.trim` (`KVCache.swift:1683`);
  offset-aware attention/RoPE keeps delta-only inputs correct (`Qwen2.swift`).
- FIM prompt shape `<|fim_prefix|>prefix<|fim_suffix|>suffix<|fim_middle|>`:
  as the user types, `prefix` grows (cached) and `suffix` shrinks — only the
  suffix tail is re-encoded per keystroke.
- Cost model (measured slope): per keystroke ≈ encode(suffix ~300ch ≈ 25-30ms)
  + decode(1-3 tokens ≈ 20-100ms) ⇒ **50-130ms per keystroke** — true
  real-time. Whole page can be prefilled once on file open/focus (~2s at
  large files), then generation focuses on the cursor region.
- Caveats: repetition-penalty ring primes from delta only; exact-prefix case
  must skip reuse; warm 4096-token cache pins ~100-300MB; `MLXInferenceLock`
  already serializes, so no races.

## Adaptive token-budget architecture (proposed)

1. **Pre-warm**: load model + prefill page KV cache on file open/focus.
2. **Cadence tracker**: EMA of inter-keystroke intervals.
3. **Adaptive budget**: fast typing → 1-3 tokens per call; pause (>~300ms) →
   up to newline/EOS. "Faster you type, fewer tokens predicted; slower you
   type, more time for longer predictions."
4. **Streaming ghost** (existing `generateStream`): tokens render as they
   arrive — "fill up as we go".
5. **Accept-verify**: typed chars matching the suggestion head consume it
   deterministically (no model call).
6. **Stop at first newline** in pause mode.
7. Dropdown / multi-options: deferred; complement later with the 4B chat
   model if desired.

## Product-feasibility answers

| Question | Answer (production defaults) |
|---|---|
| Suggestion per typing pause | small: ~0.7s, mid: ~1.3s, large: ~1.95s after the pause (TTFT) |
| React per keystroke | **No** — prefill is 0.67-1.95s and recomputes per call. Needs debounce (~300ms pause) or incremental KV-cache reuse. Realistic: suggestion ~1s after typing stops. |
| Dropdown of N suggestions | small file: 1.4s each → 3 ≈ **4.3s**, 5 ≈ 7.2s. mid: 2.1s each. large: ~2.9s each. **Not interactive as sequential full generations.** Would need: shared-prefill candidate sampling, or accept 2 suggestions at small files only. |
| Top suggestion + Tab | Yes — that's the current model; Tab accepts line 1 (already implemented). |
| Multi-line suggestions as variants | Do **not** use the 1.5B model — multi-line quality is poor (measured; rambles). The 4B chat model is the right tool if variants are ever wanted; FIM stays slim/fast. |

## Repeatability (determinism)

T=0.1: short completions are byte-identical across 3 generations (C/Swift/CSS
probes). Long/rambling outputs vary (Perl probe pair-sim 0.57-0.74). Suggestion
content is deterministic for typical lines.

## How to run

```sh
./run.sh harness FIMBenchmarkHarnessTests                       # full suite
./run.sh harness FIMBenchmarkHarnessTests/testFIMLanguageQualityMatrix

# Tuning (env vars forwarded via fim-bench.conf — app-hosted safe)
COMPASS_FIM_TEMPERATURE=0.1 COMPASS_FIM_TOP_P=0.9 \
COMPASS_FIM_REPETITION_PENALTY=1.1 COMPASS_FIM_MAX_TOKENS=64 \
./run.sh harness FIMBenchmarkHarnessTests
```

Skips automatically when the FIM model is not installed.

## Next candidates

1. **Stop generation at first newline** (biggest latency lever, ~45% cut,
   zero quality cost for single-line UX) — needs a service change + renderer
   contract check.
2. Incremental KV-cache reuse across keystrokes (enables per-keypress
   re-prediction; prefill currently recomputes).
3. Context-window ablation: production 1500-char assembler window vs the
   4096-token budget (quality impact of more input context unknown).
4. Multi-line variants with the 4B model, gated as an explicit user action.
