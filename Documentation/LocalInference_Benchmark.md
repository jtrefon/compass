# Local Inference Benchmark — KPI Spec (Qwen3.5-4B-MLX-4bit)

The local chat path is a fixed-model, fixed-stack product (no selector, no
variants, no multimodal — see `FIM_VariantPools_Arch.md` for the FIM
counterpart). This document defines the KPIs that gate every experiment and
the harness that collects them (`LocalBenchmarkHarnessTests`).

## KPI axes

### 1. Resource usage
| KPI | Source | Units |
|---|---|---|
| Model load time | `mlx.generate_complete.loadMs` | ms |
| Peak process RSS | `mlx.generate_complete.rssAfterGenMB` / `mlx.memory_snapshot.peakMB` | MB |
| MLX active/cache memory | `mlx.memory_snapshot.activeMB/cacheMB` | MB |
| KV cache reuse | `promptTokens` on turn 2 vs turn 1 (reuse ⇒ promptTokens ≈ suffix length) | tokens |
| Load frequency | number of `loadMs > 0` generations in a run | count |

### 2. Performance
| KPI | Source | Units |
|---|---|---|
| TTFT (wall clock, incl. load) | `mlx.first_token.prefillMs` | ms |
| Prefill throughput | promptTokens / prefillMs | tok/s |
| Generation throughput | `mlx.generate_complete.generationTokensPerSecond` | tok/s |
| Total turn latency | `mlx.generate_complete.totalMs` | ms |
| Token waste | output tokens vs golden tokens | ratio |

### 3. Quality of response
| KPI | Method |
|---|---|
| Semantic similarity | cosine(embed(answer), embed(golden)) — deterministic hashed char-n-gram embedding (dim 512, L2-normalized) built in the harness; a proxy, not a learned model |
| Completeness | fraction of golden checklist terms present in the answer |
| Verbosity ratio | answer tokens / golden tokens (target ~1; >3 = bloat) |
| Self-consistency | (future) same prompt ×3, pairwise similarity |

### 4. Agentic compliance
| KPI | Method |
|---|---|
| Valid-JSON tool-call rate | answer parses as `<tool_call>{"name":…,"arguments":{…}}</tool_call>` |
| Schema adherence | parsed call has `name` (String) + `arguments` (object) |
| Correct-tool rate | `name` equals the fixture's expected tool |
| Malformed-markup rate | answer carries tool markup that failed parsing |
| Format adherence | model answers in the instructed format when asked |

### 5. Composite
| KPI | Formula |
|---|---|
| Resource-quality frontier | quality / (peak RSS MB × totalMs s) |
| Agentic efficiency | valid-call rate × correct-tool rate × (1 − malformed rate) |

## Env knobs (experiment surface)

The harness reads the live `COMPASS_LOCAL_MODEL_*` knobs (already forwarded
by `run.sh`), mirroring the FIM `fim-bench.conf` pattern:

`COMPASS_LOCAL_MODEL_TEMPERATURE` · `_TOP_P` · `_REPETITION_PENALTY` ·
`_REPETITION_CONTEXT_SIZE` · `_CONTEXT_LENGTH` · `_MAX_KV_SIZE` ·
`_MAX_OUTPUT_TOKENS` · `_PREFILL_STEP_SIZE` · `_KV_CACHE_4BIT`

Harness control: `LOCAL_BENCH_ITERATIONS` (default 1) · `LOCAL_BENCH_TASKS`
(comma-separated id filter).

## Output

Per task-run: one NDJSON row in `<root>/.ide/logs/local-bench.ndjson` with
config, per-KPI values, and the raw answer. Console prints a `[LOCAL-BENCH]`
table (per-config aggregates) for quick reads.

## Baseline + findings (2026-08-06)

Measured via LocalBenchmarkHarnessTests (real pipeline, Qwen3.5-4B-MLX-4bit):

| Metric | Before | After | Change |
|---|---|---|---|
| Prefill (8.8K-token prompt) | ~296 tok/s (~28s) | ~373 tok/s (~24s) | +25% |
| Generation | 25-31 tps | 25-31 tps | — |
| GPU peak | 3.0GB (at 3GB hard limit) | ~3.0GB (limit removed) | — |

Wins applied:
- **MLX memory limit**: the hardcoded 3GB `Memory.memoryLimit` blocked malloc
  whenever a 2.5GB model + activations exceeded it (mlx-swift: "malloc waits on
  scheduled tasks if the limit is exceeded"). Removed; default is 1.5x the
  device recommended working set. Cache limit 128MB → 1GB. Both env-tunable.
- **Per-layer eval + `Memory.clearCache()` removed** from Qwen35TextModelInner
  (fork addition, serialized the GPU pipeline 36x per prefill chunk).

Still open (bottleneck is the vendored Qwen3.5 port, not the app — a raw
MLX baseline bypassing Compass measures the same 30-36 tps / ~350 tok/s):
- The 24 linear-attention layers run a hand-written Metal kernel (grid
  32×128×32) — kernel vs ops-fallback measured equal (~32 tps).
- No `gated_delta_update` fast op exists in mlx-swift (python mlx has one);
  generation ~30 tps is the port's per-layer cost, context-independent.
- System prompt is ~6.9K tokens — the largest practical prefill lever
  (concise tool-prompt mode, fewer tools in .chat).
- KV-4bit: **OFF as the default (2026-08-06)** — measured then reverted:
  only the 8 full-attention layers' KV is quantizable (the 24 MambaCache
  layers are state arrays), so the short-context win is ~34MB at 2K tokens
  (3% of GPU) for nil speed gain, while long-context prefill pays -11% for
  quantized writes. bf16 KV fits ~65K tokens on this 15GB machine, so the
  tradeoff only pays beyond that. Re-enable for long-context work:
  `COMPASS_LOCAL_MODEL_KV_CACHE_4BIT=1 ./run.sh benchmark-local`, and if
  long context becomes a goal, do it properly with dynamic quantization
  (bf16 until a token threshold, then quantize — the vendored TokenIterator
  has the machinery, the Qwen35 port bypasses it). Long-context fixture:
  `ctx_long_recall` (~16K-token synthesized docs).

Diagnostics: `RawMLXBaselineTests` isolates the vendor stack;
`COMPASS_GDN_KERNEL=0` / `COMPASS_GDN_TIMING=1` via local-bench.conf toggle
the linear-attention kernel and per-layer timing. FIM inline model
(Qwen2.5-Coder-1.5B) runs ≈ 8.5 tok/s — same port-level bottleneck.

## Run

```sh
./run.sh benchmark-local            # default config
COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE=512 ./run.sh benchmark-local
```
