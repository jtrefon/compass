# MLX Inference Performance Fix Proposal

> **Status:** Implemented — Phases 1-4 complete
> **Date:** September 2026
> **Investigation:** See `MLX_PERFORMANCE_ROOT_CAUSE_ANALYSIS.md` (session telemetry from `~/Projects/WordPress/.ide/logs/ai-trace.ndjson`)

## Results Summary

| Metric | Baseline | Phase 1+2 | Phase 3 | Phase 4 (final) |
|--------|----------|-----------|---------|-----------------|
| **Decode t/s** | 13 t/s | 25.3 t/s | 29.4 t/s | **30.2 t/s** |
| **Prefill t/s** | 85-200 | 362 t/s | 369 t/s | **~330 t/s** |
| **Improvement** | 1x | 1.9x | 2.3x | **2.3x** |

Target: ~50 t/s. Achieved: 30.2 t/s (60% of target, 2.3x over baseline).

The remaining gap is from Qwen3.5's hybrid architecture (24 SSM + 8 attention layers)
where the attention layers cannot be compiled (growing KV cache offsets) and the
theoretical weight-bandwidth limit (~60 t/s for 2GB 4-bit weights at 120 GB/s).

## Problem Statement

Qwen3.5-4B-MLX-4bit on M4 16GB achieves **13 t/s median decode** (expected 45–55 t/s) and **85–200 t/s prefill** (expected 661 t/s). The deficit is **4x decode, 3–8x prefill**. Intra-generation stalls reach **291 seconds**. Memory peaks at **9.75 GB** on a 16 GB machine, triggering compressor thrashing (1.9 GB compressed, 8 MB free).

The same model in llama.cpp runs with fixed memory, no pressure, and stable performance. MLX should outperform llama.cpp but does not.

## Root Causes (from investigation)

| # | Root Cause | Impact | Confidence |
|---|-----------|--------|------------|
| 1 | 4-bit KV cache forces non-fused quantized attention (no flash attention) | 2x decode + 5GB transient prefill spike | HIGH |
| 2 | `TokenIDRecorder.didSample()` calls `.item(Int.self)` — breaks asyncEval pipelining | 2x decode | HIGH |
| 3 | `mlockall` is ENOSYS on macOS — memory lock is a no-op | Compressor thrashing, stalls | HIGH |
| 4 | Telemetry spawns async Tasks per-chunk during decode | 1.2x decode + measurement contamination | HIGH |
| 5 | FIM model evicted before every chat generation (99 evictions/session) | 15 × 30s lock timeouts | HIGH |
| 6 | Thermal throttling (sustained 9.7 GB peak) | 10–15% late-session slowdown | MEDIUM |
| 7 | Active memory growth over session (2.3 GB → 3.2 GB) | Worsens pressure | MEDIUM |

---

## Proposed Fixes

### Fix 1: Default to FP16 KV cache on 16 GB machines

**Root cause addressed:** #1 (non-fused quantized attention)

**What:** Change the default KV cache quantization from 4-bit to FP16 for the Qwen3.5-4B chat model. The `LocalModelSelectionStore.isKVCache4BitEnabled()` default changes from `true` to `false`.

**Why:** The 4-bit KV cache was enabled to save 1.5 GB of resident KV memory. But it forces the non-fused `quantizedScaledDotProductAttention` path, which materializes a full `[B, heads, L, kL]` attention score matrix during prefill — a **4–8 GB transient spike** that is far larger than the 1.5 GB it saves. On a 16 GB machine, this makes memory pressure **worse**, not better.

FP16 KV enables `MLXFast.scaledDotProductAttention` (fused flash attention), which:
- Never materializes the score matrix (fused kernel)
- Halves decode time (1 kernel launch vs 3)
- Eliminates the 4–8 GB prefill transient spike
- KV cache grows from 512 MB to ~2 GB, but peak drops from 9.75 GB to ~5 GB

**Files to change:**
- `Compass/Services/LocalModels/LocalModelSelectionStore.swift` — default `false`
- `Compass/Services/LocalModels/LocalModelProcessAIService.swift` — update the `safeInferenceConfiguration` fallback (currently forces `kvCache4BitEnabled: true` when `!supportsQuantizedKVCache` — this is wrong; non-supporting models should use FP16)
- `Compass/Services/LocalModels/LocalModelInferenceConfiguration.swift` — update the stale comment ("FP16 = ~4× KV memory but faster decode" → correct to "FP16 enables flash attention: fused kernel, no score matrix materialization, lower transient peak")
- `Compass/Services/LocalModels/LocalModelSettingsViewModel.swift` — update default
- `Compass/Components/LocalModelSettingsView.swift` — update toggle label/description

**Boy Scout cleanups:**
- The `safeInferenceConfiguration` branch in `LocalModelProcessAIService` (lines 181–193) constructs a full `LocalModelInferenceConfiguration` just to flip one field. This should use a `with(kvCache4BitEnabled:)` method on the struct instead of the verbose initializer. Add a `func with(kvCache4BitEnabled: Bool) -> LocalModelInferenceConfiguration` to the struct (value semantics — idiomatic Swift copy-with).
- Remove the stale comment on line 100–106 of `LocalModelInferenceConfiguration.swift` that incorrectly describes the FP16/4-bit tradeoff.

**Design pattern:** Value semantics with a copy-with method (idiomatic Swift, matches `CGPoint` etc.)

**Risk:** LOW. FP16 KV is the standard MLX path. 4-bit KV remains available via the settings toggle for machines with more RAM where the resident savings matter more than the transient spike. The prefix cache hash already includes `kv4=`, so a flip invalidates the old cache cleanly.

**Verification:**
- `COMPASS_CONFIG=Release ./run.sh benchmark-local` — compare decode/prefill t/s before and after
- Check `mlx.generate_complete` telemetry: `kvCache4Bit` should be `false`, `generationTokensPerSecond` should improve
- Check `mlx.memory_snapshot` telemetry: `genPeakMB` should drop significantly
- Verify KV cache reuse still works (prefix cache hash changes, first generation re-prefills, subsequent generations hit)

---

### Fix 2: Eliminate per-token GPU sync in TokenIDRecorder

**Root cause addressed:** #2 (broken asyncEval pipelining)

**What:** Replace the per-token `.item(Int.self)` call in `TokenIDRecorder.didSample()` with a lock-free atomic counter. Collect the actual token IDs **after generation** from the token loop handler, not during sampling.

**Why:** The `TokenIDRecorder` wraps the logit processor and calls `token.item(Int.self)` on every sampled token. This forces a GPU→CPU synchronization on every token, destroying the `asyncEval` pipelining that gives MLX its throughput. The vendor code (`TokenRing`) explicitly avoids CPU←GPU sync for this reason.

The token IDs are only needed in two places:
1. `cacheEntry.set(tokenIds: promptTokenIds + streamResult.generatedTokenIds, ...)` — **after generation**, for KV-reuse bookkeeping
2. `recorder.tokenIDs.count` — during generation, for the context usage gauge estimate

The count can be tracked with an atomic counter (no GPU sync). The actual IDs can be collected from the `generateLoopTask`'s token stream, which already yields `Int` token values (see `Evaluate.swift:789`: `return previousY.tokens.item(Int.self)` — this sync happens in the loop handler, not in the sampler).

**Approach:**

1. **Add a `TokenIDCollector` to the generation loop** — a simple `[Int]` buffer that the `processGeneration` loop appends to when it receives each token from the stream. The `generateLoopTask` already calls `iterator.next()` which returns `Int?` — the token ID is available without any additional GPU sync.

2. **Simplify `TokenIDRecorder`** — remove the `_tokenIDs` array and the `NSLock`. Keep only the `upstream` processor forwarding (repetition penalty). Add a `tokenCount` atomic counter (using `OSAtomicIncrement64` or `AsyncStream` element counting).

3. **Wire the collector** — in `processGeneration`, the `for await generation in stream` loop already processes `.chunk` events. Add token ID collection alongside it. The `generateLoopTask` handler (`TextToolTokenLoopHandler`) receives raw token IDs internally; we need to expose them or collect from the stream.

**Alternative (simpler, lower risk):** Keep `TokenIDRecorder` but replace `.item(Int.self)` with a deferred collection. Instead of materializing the token immediately, append the **lazy MLXArray** to a buffer. After generation completes, call `.item(Int.self)` on all arrays in a single batch (one GPU sync instead of N). The MLXArrays remain valid because they reference the same GPU memory.

**Preferred approach:** The deferred batch collection — it's a minimal change (3 lines in `TokenIDRecorder`, no changes to the generation loop or handler), and it eliminates the per-token sync while preserving the exact same post-generation data.

**Files to change:**
- `Compass/Services/LocalModels/TokenIDRecorder.swift` — replace per-token `.item()` with lazy array buffer + batch materialization

**Implementation sketch:**
```swift
final class TokenIDRecorder: LogitProcessor, @unchecked Sendable {
    private var upstream: (any LogitProcessor)?
    private let lock = NSLock()
    private var _pendingTokens: [MLXArray] = []  // lazy — no GPU sync
    private var _tokenCount: Int = 0

    init(upstream: (any LogitProcessor)?) {
        self.upstream = upstream
    }

    /// Materialized token IDs — calls .item() in batch AFTER generation.
    /// Do NOT call during generation (forces GPU sync per token).
    var tokenIDs: [Int] {
        lock.lock()
        let pending = _pendingTokens
        _pendingTokens = []
        lock.unlock()
        return pending.map { $0.item(Int.self) }
    }

    /// Lightweight count — no GPU sync. Safe during generation.
    var tokenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _tokenCount
    }

    func prompt(_ prompt: MLXArray) {
        var p = upstream
        p?.prompt(prompt)
        upstream = p
    }

    func process(logits: MLXArray) -> MLXArray {
        upstream?.process(logits: logits) ?? logits
    }

    func didSample(token: MLXArray) {
        lock.lock()
        _pendingTokens.append(token)  // lazy — no sync
        _tokenCount += 1
        lock.unlock()
        var p = upstream
        p?.didSample(token: token)
        upstream = p
    }
}
```

**Callers to update:**
- `NativeMLXGenerator.swift` line 726: `recorder.tokenIDs.count` → `recorder.tokenCount`
- `NativeMLXGenerator.swift` line 779: `recorder.tokenIDs.count` → `recorder.tokenCount`
- `NativeMLXGenerator.swift` line 794: `result.generatedTokenIds = recorder.tokenIDs` — this is **after** generation, so the batch `.item()` is fine (one sync)
- `NativeMLXGenerator.swift` line 796: `recorder.tokenIDs.count` → `recorder.tokenCount`

**Boy Scout cleanups:**
- The `NSLock` in `TokenIDRecorder` is fine for the count, but consider `os_unfair_lock` (lower overhead, no priority inversion) — match the pattern used elsewhere in the vendored MLX code.
- Update the class doc comment to explain the lazy/batch pattern and why per-token `.item()` is forbidden.

**Design pattern:** Lazy evaluation + batch materialization (deferred side-effects). The MLXArray is a lazy graph node — deferring `.item()` until after the generation loop preserves asyncEval pipelining.

**Risk:** LOW. The token IDs are collected in the same order, just materialized in batch. The MLXArrays remain valid references to GPU memory. The only behavioral change is that `tokenIDs` is now empty after first access (one-shot materialization) — callers must not call it twice.

**Verification:**
- `COMPASS_CONFIG=Release ./run.sh benchmark-local` — decode t/s should improve ~2x
- Verify `generatedTokenIds` in `StreamResult` is still correct (same count, same values)
- Verify KV cache reuse still works (common prefix trim math depends on exact token IDs)
- Run `RawMLXBaselineTests` — raw MLX throughput should now match Compass throughput (confirming the wrapper overhead is gone)

---

### Fix 3: Gate telemetry behind compile-time flag

**Root cause addressed:** #4 (telemetry overhead during decode)

**What:** Introduce a compile-time `COMPASS_TELEMETRY_ENABLED` flag (active in Debug, inactive in Release). Gate all `AIToolTraceLogger.shared.log(...)` calls behind this flag. Release builds have zero telemetry overhead.

**Why:** The WordPress session generated 8,000+ telemetry events. At 13 t/s decode, the chunk timing alone spawns ~400 async Tasks/second — each hopping to the `@MainActor` `AIToolTraceLogger`, serializing JSON, and writing to disk. This competes with `asyncEval` for Swift's cooperative thread pool.

**Approach:**

1. **Add a `TelemetryGate` utility** — a compile-time check that no-ops in Release:
```swift
enum TelemetryGate {
    #if COMPASS_TELEMETRY_ENABLED
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}
```

2. **Add a conditional logging extension** to `AIToolTraceLogger`:
```swift
extension AIToolTraceLogger {
    @inline(__always)
    func logIfEnabled(type: String, data: [String: Any]) {
        guard TelemetryGate.isEnabled else { return }
        log(type: type, data: data)
    }
}
```

3. **Replace all `Task { await AIToolTraceLogger.shared.log(...) }` calls** in the decode loop with `AIToolTraceLogger.shared.logIfEnabled(...)`. The `Task` wrapper is also eliminated — in Debug, the call is already async-safe via the internal `DispatchQueue`; in Release, the entire call is eliminated at compile time.

4. **Keep critical-path telemetry** (non-perf-sensitive) ungated:
   - `mlx.model_loaded` — once per load
   - `mlx.generate_complete` — once per generation
   - `mlx.memory_lock` — once per session
   - `mlx.device_info` — once per session

5. **Gate perf-sensitive telemetry** (per-chunk):
   - `mlx.chunk_timing` — gated
   - `mlx.first_token` — gated (redundant with `mlx.generate_complete`)
   - `mlx.inference_timeline` — gated (redundant)
   - `mlx.memory_snapshot` — gated (except before/after load)
   - `mlx.vm_stat` — gated
   - `mlx.memory_gate` — gated
   - `mlx.kv_cache` — gated

**Files to change:**
- `Compass/Services/ToolExecutionSupport.swift` — add `TelemetryGate` and `logIfEnabled`
- `Compass/Services/LocalModels/NativeMLXGenerator.swift` — replace per-chunk `Task { await AIToolTraceLogger.shared.log(...) }` with `AIToolTraceLogger.shared.logIfEnabled(...)`; remove the `Task` wrapper
- `Compass.xcodeproj` — add `COMPASS_TELEMETRY_ENABLED=1` to Debug build settings only

**Boy Scout cleanups:**
- The `Task { await AIToolTraceLogger.shared.log(...) }` pattern is used 15+ times in `NativeMLXGenerator.swift`. Each spawns an unstructured `Task` that hops to `@MainActor`. This is wasteful even in Debug — the `AIToolTraceLogger` already has an internal `DispatchQueue` for file I/O. Remove the `Task` wrapper and call `logIfEnabled` directly (the `@MainActor` isolation on `AIToolTraceLogger` is itself questionable — it should be an actor or use the internal queue exclusively, not require `@MainActor`).
- Consider converting `AIToolTraceLogger` from `@MainActor final class` to `actor` — the `@MainActor` isolation forces every caller to hop to the main thread, which is unnecessary for file I/O. This is a larger refactor and can be deferred.

**Design pattern:** Compile-time feature flag with `@inline(__always)` guard — zero runtime cost in Release, full telemetry in Debug.

**Risk:** LOW. Telemetry is observability-only, not functional. Release builds already don't have `#if DEBUG` hooks. The `COMPASS_TELEMETRY_ENABLED` flag is orthogonal to `DEBUG` — it can be enabled in Release for benchmark runs via `COMPASS_CONFIG=Release COMPASS_TELEMETRY_ENABLED=1`.

**Verification:**
- `COMPASS_CONFIG=Release ./run.sh benchmark-local` — decode t/s should improve
- Verify `ai-trace.ndjson` is empty (or minimal) in Release without the flag
- Verify `ai-trace.ndjson` is populated in Debug
- Verify `COMPASS_CONFIG=Release COMPASS_TELEMETRY_ENABLED=1 ./run.sh benchmark-local` still produces full telemetry

---

### Fix 4: Eliminate redundant FIM eviction

**Root cause addressed:** #5 (FIM model churn, lock contention)

**What:** Remove the unconditional `await InferenceUnloadRegistry.shared.unloadAll(labels: [InferenceUnloadRegistry.fimLabel])` call on line 193 of `NativeMLXGenerator.swift`. Keep only the conditional eviction (line 187–192) that fires when `freePages < 20_000`.

**Why:** The code currently evicts FIM **twice** — once conditionally (line 187–192, only when memory is low) and once **unconditionally** (line 193, every single generation). The unconditional eviction causes 99 `pre_evict_fim` events per session, 15 lock timeouts of 30 seconds each, and forces a full FIM model reload on every completion request.

The unconditional eviction was likely added as a safety net but defeats the purpose of the conditional check. With Fix 1 (FP16 KV, lower memory peak), the conditional eviction should rarely fire.

**Files to change:**
- `Compass/Services/LocalModels/NativeMLXGenerator.swift` — remove line 193

**Boy Scout cleanups:**
- The conditional eviction block (lines 185–192) has a magic number `20_000` for the free pages threshold. Extract this to a named constant: `private static let fimEvictionFreePageThreshold = 20_000` with a doc comment explaining the rationale.
- The 200ms sleep after eviction (line 191) is a magic number. Extract to a constant with a comment explaining the compressor drain time.

**Design pattern:** Remove redundant safety net; trust the conditional guard. KISS principle.

**Risk:** LOW–MEDIUM. If memory pressure is higher than expected without the unconditional eviction, the conditional check may not fire early enough. Monitor `mlx.pressure` events after the change. If critical pressure events increase, re-add a lighter-weight eviction (e.g., only evict if FIM was loaded > 30 seconds ago).

**Verification:**
- `COMPASS_CONFIG=Release ./run.sh benchmark-local` — lock wait times should drop
- Check `mlx.lock_timeout` events — should decrease from 15/session to 0–2
- Check `mlx.memory_gate` events — `pre_evict_fim` count should drop from 99 to < 10
- Verify FIM completions still work (inline completion should be responsive after chat generation)

---

### Fix 5: Implement per-region `mlock()` for CPU-side allocations

**Root cause addressed:** #3 (mlockall is ENOSYS on macOS)

**What:** Replace the no-op `mlockall` call with per-region `mlock()` on the model weights mmap. The MLX model loader mmaps weight files from disk — `mlock()` on those pages prevents the compressor from touching them.

**Why:** `mlockall` returns `ENOSYS` (78) on macOS — it's not implemented. The current code knows this (the comment says so) but does nothing about it. Per-region `mlock()` IS implemented on macOS and can lock specific memory ranges.

The model weights (~3 GB) are the largest CPU-side allocation. Locking them prevents the compressor from compressing 3 GB of weights, which is the primary source of compressor thrashing.

**Approach:**

1. **Add a `MemoryLocker` utility** that wraps per-region `mlock()`:
```swift
enum MemoryLocker {
    /// Locks a memory region so the OS cannot compress or swap it.
    /// Returns true if successful. On macOS, mlock() is per-region
    /// (mlockall is ENOSYS).
    static func lock(region: UnsafeRawBufferPointer) -> Bool {
        let result = mlock(region.baseAddress, region.count)
        return result == 0
    }
}
```

2. **Apply after model load** — in `MLXModelRepository.loadModelContainer`, after the container is loaded, iterate the model's weight arrays and `mlock()` their underlying buffers. MLX arrays expose `.contents` or can be converted to `UnsafeRawBufferPointer`.

3. **Remove the `ProcessMemoryLock.engageIfEnabled()` call** — it's a no-op and misleading. Replace with the per-region lock.

**Alternative (lower risk, lower benefit):** Keep `ProcessMemoryLock` as-is (it's already a no-op) but add a comment that it's intentionally inert on macOS. Focus on the other fixes first — with Fix 1 (FP16 KV, lower peak), the compressor pressure should drop significantly even without `mlock()`.

**Preferred approach:** The alternative — defer the `mlock()` implementation. Fix 1 reduces the peak from 9.75 GB to ~5 GB, which should eliminate most compressor pressure. If telemetry still shows significant compression after Fixes 1–4, implement per-region `mlock()` as a follow-up.

**Files to change (deferred):**
- `Compass/Services/LocalModels/ProcessMemoryLock.swift` — add per-region `mlock()` implementation
- `Compass/Services/LocalModels/MLXModelRepository.swift` — call after model load

**Boy Scout cleanups (now):**
- Update the `ProcessMemoryLock` doc comment to clearly state it's inert on macOS and that per-region `mlock()` is the follow-up (the current comment buries this in a code comment on line 47–52).
- Remove the `Task { await AIToolTraceLogger.shared.log(...) }` in `engageIfEnabled()` — it logs every session that the lock failed, which is noise. Gate it behind `TelemetryGate.isEnabled` (Fix 3).

**Risk:** MEDIUM. `mlock()` can fail if the process exceeds `RLIMIT_MEMLOCK` (though it's unlimited by default on macOS). Locking 3 GB of weights reduces available memory for other processes. Deferred to follow-up.

**Verification (when implemented):**
- Check `mlx.memory_lock` telemetry — `engaged` should be `true`, `errno` should be `0`
- Check `mlx.vm_stat` telemetry — `compressorPages` should decrease
- Monitor system memory pressure via `vm_stat` — no increase in critical pressure events

---

### Fix 6: Reduce default context length for 16 GB machines

**Root cause addressed:** #1, #3, #6 (memory pressure, thermal)

**What:** Reduce the default context length from 132,096 to 32,768 for the Qwen3.5-4B model on 16 GB machines. The `mlxMaxKVSize` (currently `contextLength / 2`) would drop from 66,048 to 16,384.

**Why:** 132K context on a 16 GB machine is aggressive. The KV cache at 66K tokens (4-bit) is 512 MB, but the attention score matrix during prefill is `[1, 8, 4, 512, 66048]` = 4.1 GB per layer. With FP16 KV (Fix 1), the score matrix is still `[1, 8, 4, 512, 16384]` = 1 GB — much more manageable.

The KV cache reuse telemetry shows 92% average reuse ratio — most of the 132K context is never used. The conversation grows to ~32K tokens naturally; 132K is wasted headroom that inflates the KV cache and score matrices.

**Files to change:**
- `Compass/Services/LocalModels/LocalModelCatalog.swift` — `defaultContextLength: 65536` → `32768` (the catalog default; the user can still increase via settings)
- `Compass/Services/LocalModels/LocalModelInferenceConfiguration.swift` — update `mlxMaxKVSize` comment

**Boy Scout cleanups:**
- The `mlxMaxKVSize` computed property (`contextLength / 2`) is a magic ratio. Extract to a named constant or make it configurable. The comment says "half the context window is a reasonable default" but doesn't explain why half (not quarter, not full).

**Design pattern:** Conservative defaults with user override capability. The settings slider already allows up to 262K.

**Risk:** LOW. Users who need longer context can increase it via settings. The 32K default is still generous for most coding sessions.

**Verification:**
- `COMPASS_CONFIG=Release ./run.sh benchmark-local` — decode and prefill t/s should improve
- Check `mlx.memory_snapshot` — `genPeakMB` should drop
- Verify multi-turn conversations still work (KV cache reuse at 32K context)

---

## Implementation Phasing

### Phase 1: High-impact, low-risk (do first)

| Fix | Expected decode improvement | Expected prefill improvement | Risk |
|-----|---------------------------|-----------------------------|------|
| Fix 1: FP16 KV cache default | 2x (13 → ~26 t/s) | 3x (transient peak halved) | LOW |
| Fix 2: TokenIDRecorder batch | 2x (26 → ~45 t/s) | — | LOW |
| Fix 3: Telemetry gating | 1.2x (45 → ~50 t/s) | — | LOW |

**Combined expected result:** ~50 t/s decode (vs 13 t/s current), ~5 GB peak (vs 9.75 GB current)

### Phase 2: Medium-impact, low-risk (do second)

| Fix | Expected improvement | Risk |
|-----|---------------------|------|
| Fix 4: FIM eviction | Eliminate 15 × 30s lock timeouts | LOW–MEDIUM |
| Fix 6: Reduce default context | Lower memory pressure, faster prefill | LOW |

### Phase 3: Deferred (do if telemetry shows remaining issues)

| Fix | Expected improvement | Risk |
|-----|---------------------|------|
| Fix 5: Per-region mlock() | Eliminate compressor thrashing | MEDIUM |

---

## Boy Scout Rule: Additional Cleanups

These are not performance fixes but should be cleaned up in the same PR per the Boy Scout Rule:

1. **`AIToolTraceLogger` `@MainActor` isolation** — the class is `@MainActor` but does file I/O on a background `DispatchQueue`. The `@MainActor` isolation forces every caller to hop to the main thread. Convert to an `actor` or remove `@MainActor` (the internal queue already serializes I/O). This is a larger refactor — defer to a follow-up PR but note it in the code.

2. **`LocalModelInferenceConfiguration` stale comments** — the comment on lines 100–106 describes the FP16/4-bit tradeoff incorrectly ("FP16 = ~4× KV memory but faster decode"). Update to reflect the actual tradeoff discovered in the investigation.

3. **`ProcessMemoryLock` misleading telemetry** — logs `engaged: false, errno: 78` every session. This is noise. Gate behind `TelemetryGate` or remove (the information is already in the code comment).

4. **Magic numbers in `NativeMLXGenerator`** — `20_000` (free page threshold), `200` (compressor drain ms), `16` (chunk timing sample count), `50` (chunk timing cadence). Extract to named constants with doc comments.

5. **`safeInferenceConfiguration` in `LocalModelProcessAIService`** — constructs a full `LocalModelInferenceConfiguration` to flip one field. Add a `with(kvCache4BitEnabled:)` method to the struct (idiomatic Swift copy-with).

---

## Testing Plan

### Per-fix verification

Each fix is verified independently before moving to the next:

1. **Build:** `./run.sh build` (Debug) + `./run.sh build-release` (Release)
2. **Unit tests:** `./run.sh test`
3. **Benchmark:** `COMPASS_CONFIG=Release ./run.sh benchmark-local` — compare t/s, peak MB, prefill t/s
4. **Telemetry inspection:** Check `ai-trace.ndjson` for expected changes

### Integration verification (after all Phase 1 fixes)

1. **Manual test:** Run the agent on `~/Projects/WordPress` with a multi-turn conversation
2. **Telemetry:** Verify `mlx.generate_complete` shows ~50 t/s decode, ~300+ t/s prefill
3. **Memory:** Verify `mlx.memory_snapshot` shows < 6 GB peak
4. **Stalls:** Verify `mlx.chunk_timing` shows 0 stalls > 500ms (in Debug with telemetry enabled)
5. **Lock waits:** Verify `mlx.lock_timeout` count is 0

### Regression checks

- KV cache reuse still works (common prefix trim math)
- FIM completions still work after chat generation
- Multi-turn conversations maintain context
- Tool calls are correctly parsed
- No crashes under memory pressure

---

## Files Changed (Summary)

| File | Fixes | Changes |
|------|-------|---------|
| `Compass/Services/LocalModels/TokenIDRecorder.swift` | 2 | Lazy batch materialization, atomic count |
| `Compass/Services/LocalModels/LocalModelSelectionStore.swift` | 1 | Default `kvCache4BitEnabled` → `false` |
| `Compass/Services/LocalModels/LocalModelProcessAIService.swift` | 1 | `safeInferenceConfiguration` cleanup |
| `Compass/Services/LocalModels/LocalModelInferenceConfiguration.swift` | 1, 6 | Comment corrections, `with()` method |
| `Compass/Services/LocalModels/LocalModelSettingsViewModel.swift` | 1 | Default update |
| `Compass/Components/LocalModelSettingsView.swift` | 1 | Toggle description update |
| `Compass/Services/LocalModels/NativeMLXGenerator.swift` | 2, 3, 4 | Telemetry gating, recorder.count, FIM eviction, magic numbers |
| `Compass/Services/LocalModels/LocalModelCatalog.swift` | 6 | Default context length |
| `Compass/Services/LocalModels/ProcessMemoryLock.swift` | 3, 5 | Telemetry gating, doc cleanup |
| `Compass/Services/ToolExecutionSupport.swift` | 3 | `TelemetryGate`, `logIfEnabled` |
| `Compass.xcodeproj` | 3 | `COMPASS_TELEMETRY_ENABLED` build setting |

---

## Expected Outcome

| Metric | Current | Expected after Phase 1 | Expected after Phase 1+2 |
|--------|---------|----------------------|------------------------|
| Decode t/s (median) | 13 | ~50 | ~50 |
| Prefill t/s | 85–200 | ~300+ | ~400+ |
| Peak memory | 9.75 GB | ~5 GB | ~4 GB |
| Stalls > 500ms | 321/session | < 10 | 0 |
| Lock timeouts | 15/session | < 5 | 0 |
| Compressor pages (max) | 495k (1.9 GB) | < 100k (390 MB) | < 50k (195 MB) |

This would bring MLX performance in line with (or exceeding) llama.cpp on the same hardware, as expected.
