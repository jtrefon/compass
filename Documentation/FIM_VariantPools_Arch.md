# Adaptive FIM Variant Pools — Architecture

Status: **Canonical architecture for the variant-pool feature.** Written so the
design survives session loss: after any interruption, reload this file and the
implementation resumes from the documented phase list. Grounded in
`Documentation/FIM_Spec.md` (product contract) and `FIM_Benchmark.md`
(measured numbers).

## 1. Goal

When the user types over a suggestion (rejecting it), the engine must NOT
re-predict the same suggestion on every keystroke. Instead:

- **Chain a pool of up to 5 alternative variants in the background** (shared
  prefill, hard-banned first tokens, deterministic — no temperature gambling).
- **Serve with zero added latency** from a session-lifetime pool store with
  byte-budget eviction.
- A user who keeps typing is rejecting the suggestion — their keystrokes are
  free inference budget for alternatives, and the dropdown (previously
  rejected for 4.3s+ synchronous latency) becomes an on-demand view of the
  already-warm pool.

## 2. Component map

```
Keystroke ──► MainActor (typing UX): gate → accept-verify → pool retrieval → publish
                        │  (no inference, sub-ms only)
                        ▼
              VariantPoolService (actor, detached chain)
                        │  owns: pool store, chain loop, dedup, ranking
                        ▼
              FIMInferenceService (actor, MLX threads, KV reuse)
                        └─ banned-token LogitProcessor + temp ladder
```

| Type | Role | Status |
|---|---|---|
| `InlineCompletionVariant` | id, text, temperature, bannedTokenCount, rankScore, createdAt | Phase B |
| `VariantPool` | anchor signature (buffer tail + cursor), paneID, variants (rank-sorted), lastHitAt, byteSize | Phase B |
| `VariantPoolStore` | `[paneID: [VariantPool]]`; longest-anchor retrieval; LRU eviction under byte budget; **session lifetime** (default 256KB budget, env-overridable) | Phase B |
| `VariantPoolService` (actor) | chain loop; re-anchor to latest context between variants; dedup; rank; cancel/restart | Phase B |
| `FIMBannedTokenProcessor: LogitProcessor` | zeroes banned token logits (−∞) before sampling — deterministic exclusion (`Vendor/mlx-swift-lm/.../Evaluate.swift:19-31`) | Phase A |
| `InlineCompletionDropdown` | arrow/Tab/Enter/Escape; reads the pool only — zero inference behind it | Phase E |

Modified: `FIMInferenceService` (variant decode path, first-token capture),
`InlineCompletionModels.swift` (request carries `bannedTokenIDs` +
`temperature`), `CompletionInferenceService` (pass-through),
`LineCompletionEngine` (pool integration), `LineCompletionResultCache`
(actor-ize), `TextViewRepresentable+Coordinator` (dropdown keys), harness.

## 3. Pool anchoring & retrieval

- Each pool records its **branch signature**: the buffer tail (last ~80 chars
  before cursor) + cursor position at creation.
- Retrieval per keystroke: among the pane's pools, those whose anchor is a
  **suffix of the current buffer**; pick the **longest anchor** (most recent
  branch on the user's typing path).
- Backspace re-anchors to an older pool → instant serve (mistype/backtrack).
  Pools live for the session (bytes only); eviction = LRU under the byte
  budget. Per-pane reset on file switch.
- Chaotic typing: multiple pools coexist; each deviation creates one; active
  = longest-anchor match.

## 4. Variant generation — the efficiency core

All variants share the prompt (they differ only in sampling):

1. **Prefill once** (KV-reuse machinery, warm).
2. **Variant 1**: standard params (temp 0.1, no ban) — the primary suggestion.
3. **Variants 2-5**: ban the accumulated first-token IDs of prior variants via
   `FIMBannedTokenProcessor`, temp ladder 0.3/0.5/0.5/0.7 for tail diversity.
4. **Between variants, decode from the warm cache — the K-token trick**: trim
   the cache back to `promptLen - K` (K=8) and prefill the last K prompt
   tokens, then decode with the ban set. Re-prefilling identical tokens over
   identical cache content yields identical K/V (deterministic overwrite) —
   semantically exact at ~5ms. The harness verifies transparency (same-prompt
   consecutive calls must be byte-identical). Fallback if the trick is
   finicky: full re-prefill per variant (~2-4s pool, still workable).
5. **First-token capture**: the service records the first generated token ID
   per variant (captured in the LogitProcessor's `didSample` — text→token
   round-trips are fuzzy and must not be used).

Cost model (measured decode ~85 tok/s): pool of 5 ≈ 0.5-0.7s total, fully
background. `MLXInferenceLock` already serializes with the chat model — idle
while typing, so the chain owns the budget.

**Chain loop discipline**: before each variant, re-read the latest snapshot;
if the context diverged from the pool's anchor, abort and restart the chain
for the new context (cheap with KV reuse) rather than decoding stale branches.

## 5. Engine integration (keystroke flow)

1. Keystroke → gate (unchanged)
2. **Accept-verify generalized to the pool**: consume the head of the first
   pool variant whose head the typed text extends — typing over suggestion 1
   can surface suggestion 2; publish remainder, no model call
3. Pool retrieval (longest-anchor) → hit: publish pool[0], no inference
4. Miss (deviation): create pool + trigger chain; publish variant 1
   immediately (adaptive budget); chain fills 2-5 in background
5. **Rejection demotion**: `recentRejections` ≥ threshold → demote pool[0],
   promote pool[1] as auto-suggestion
6. **Ghost flicker control**: re-publish only when pool[0] changes and
   >150ms since last publish
7. Tab → accept highlighted (default pool[0]); dropdown: arrows move
   highlight, **Tab or Enter accepts the highlighted variant**, Escape
   closes; file switch/invalidate clears pane pools

## 6. Threading

| Concern | Owner |
|---|---|
| Typing UX (gate, accept-verify, publish, dropdown render) | MainActor — sub-ms only |
| Chain loop, pool store, dedup, rank | `VariantPoolService` actor (detached tasks) |
| MLX inference, KV reuse, banned sampling | `FIMInferenceService` actor + MLX threads |
| Result cache | own actor |
| Snapshot building | main for now; off-main as polish if jank appears |

## 7. Harness benchmarks (gates)

- `testFIMBannedTokenDeterminism` — same prompt, ban set → different first
  token, reproducible; consecutive same-prompt calls byte-identical
  (validates the K-token trick)
- `testFIMVariantChainCost` — 1 prefill + 5 variants: total fill time,
  per-variant cost at budgets 8/16
- `testFIMVariantPoolRecall` — **headline metric**: 49-site corpus, pool-of-5
  recall (≥1 variant exact) vs single-shot exact-match (~45%) — decides if
  alternatives are useful, not just different
- Pool store unit tests: longest-anchor retrieval, backtrack, byte-budget
  LRU, dedup
- Engine unit tests: deviation → chain trigger, pool hit → zero model calls,
  rejection demotion

## 8. Phases

- **A. Variant sampling core** ✅ DONE (2026-08-05): `FIMBannedTokenProcessor`
  (hard logit exclusion composed with the repetition processor + first-token
  capture), service variant API (`bannedTokenIDs`, custom
  `TokenIterator`+`generateTask` path, trim-back-K exact-prefix decode,
  `lastGeneratedFirstTokenID`), request plumbing. Verified: same-prompt
  decode byte-identical (trim-back-K transparent); ban changes the first
  token deterministically (286 → 853); warm variants 131-162ms each; 5-variant
  chain ~600ms warm (2.2s incl. one-time model load); all outputs/first tokens
  distinct. Full regression: matrix 22/49, per-keystroke TTFT 174ms.
- **B. Pool store + service** ✅ DONE (2026-08-05): `InlineCompletionVariant`,
  `VariantPool`, `VariantPoolStore` (actor; longest-anchor retrieval over the
  buffer region before the branch cursor — backtracking re-anchors to older
  pools; byte-budget LRU eviction), `VariantPoolService` (actor; detached
  chain: seeded variant 1 + 4 banned/temp-ladder variants, dedup via edit
  distance, revision-abort on new deviation, `onVariantsChanged` callback).
  Unit tests: 8/8 (store anchoring/backtrack/eviction/reset; chain fills to 5
  with correct ban accumulation; dedup; deviation aborts).
- **C. Engine integration** ✅ DONE (2026-08-05): pool consumption
  (accept-verify generalized — best variant whose head the buffer extends,
  zero model calls), deviation detection (pool/lastShown context existed +
  head miss) → standard prediction → seeded `registerDeviation` (first token
  via `CompletionInferring.lastGeneratedFirstTokenID`), rejection demotion
  (`demoteTop` on ranker reject), ghost flicker throttle (150ms), pool reset
  on invalidate, `onVariantsChanged` re-publish. Factory wires one shared
  provider into the inference service + pool service (single MLX container).
  Engine tests: 9/9 (incl. deviation-seeds-pool + pool-hit-skips-inference +
  chain-fills-seeded-pool with ban propagation).
- **D. Pool-recall + chain benchmarks** ✅ DONE (2026-08-05):
  `testFIMVariantPoolRecall` — single-shot exact-match **23/49 (47%)** vs
  pool-of-5 recall **29/49 (59%)**, +6 sites (26% relative gain). The banned
  alternatives add real value. Quality gate passed.
- **E. Dropdown UI** ✅ DONE (2026-08-05): `InlineCompletionDropdownView`
  (subview near the cursor, highlighted rows, 5 max); Ctrl+Space opens it
  from the warm pool (zero inference behind it), ArrowUp/Down navigate,
  Tab/Enter accept the highlighted variant, Escape closes, typing closes,
  0.25s refresh timer while open, repositioned on scroll/layout.
- **F. Docs + polish** ✅ DONE (2026-08-05): benchmark doc updated with
  variant-pool results; spec non-goal pivoted (dropdown = warm-pool view).
  Deferred polish (no jank measured, revisit if it appears): cache actor
  extraction, snapshot building off-main.
- **C. Engine integration**: accept-verify generalization, chain trigger,
  demotion, throttle, invalidation; engine tests
- **D. Pool-recall + chain benchmarks** (quality/feasibility gate)
- **E. Dropdown UI**: component + keyboard nav (arrows/Tab/Enter/Escape)
- **F. Docs + polish**: spec/benchmark updates, cache actor, snapshot off-main

Each phase lands with build + tests + harness green.

## 9. Decisions (user-confirmed 2026-08-05)

- Pool lifetime = session; eviction = LRU under byte budget (default 256KB,
  env-overridable). Memory is trivial (8 pools × 5 variants × ~200 chars ≈
  8KB) — budget cap is a safety floor only.
- Auto-suggestion = top-ranked pool variant (ranker + rejection demotion
  make it strictly better than the old single prediction).
- Dropdown: arrow keys select, Tab/Enter accept the highlighted variant
  (non-default), Escape closes. Built last.
- Variants 2-5: hard-ban accumulated first tokens (deterministic) + temp
  ladder — never temperature-only randomization.

## 10. Risk register

- K-token trim-back exactness — harness transparency test; fallback = full
  re-prefill per variant
- Second-best first tokens may be weaker — pool-recall metric decides;
  mitigations: temp ladder, ban-2-tokens for later variants
- Background CPU during typing — measure (budget 8 caps per-variant cost)
- Ghost flicker — publish throttle
- Pool staleness on heavy edits — anchor mismatch + LRU handles
