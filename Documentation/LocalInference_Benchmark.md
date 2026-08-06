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

## Current baseline (2026-08-06, before tuning)

Measured from a two-turn local chat trace: generation 22.9 → 29.1 tok/s,
TTFT (incl. load) ≈ 30 s for an 8813-token prompt (prefill ≈ 296 tok/s —
**the primary tuning target**; generation tps is secondary), RSS ≈ 341-440 MB.
FIM inline model (Qwen2.5-Coder-1.5B) runs ≈ 8.5 tok/s (0.118 s/token).

## Run

```sh
./run.sh benchmark-local            # default config
COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE=512 ./run.sh benchmark-local
```
