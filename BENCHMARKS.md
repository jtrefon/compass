# Compass Benchmarks

> Numbers we measured, not numbers we hope for.

Every metric here is produced by `./run.sh benchmark` — a test suite that runs **the real app
code** (real FAISS bridge, real vector store, real embedding models), not mocks. Results are
printed as `[BENCH]` lines and written to JSON at `.build-tests/benchmarks/latest.json`.

The benchmark workflow runs on every release and on demand:
[Actions → Benchmark](https://github.com/jtrefon/compass/actions/workflows/benchmark.yml).

## How to run

```sh
./run.sh benchmark
```

Requires: Apple Silicon Mac, macOS 26+, Xcode 26+. Takes ~2 minutes after the first build.

## Baseline — M4 MacBook Pro, 2026-08-03 (Debug build, test-hosted process)

| Metric | Value | What it means |
|---|---|---|
| `ram.baseline_mb` | 24.2 MB | Test-host process baseline (app + test bundle loaded) |
| `vector.add_2000_ms` | 157.7 ms | 2000 entries into the real FAISS HNSW store |
| `vector.add_per_entry_ms` | 0.08 ms | Per-vector add |
| `vector.search_p50_ms` | 0.11 ms | Semantic search, median (2,000-vector index) |
| `vector.search_p95_ms` | 0.46 ms | Semantic search, 95th percentile |
| `vector.search_max_ms` | 1.09 ms | Slowest of 50 searches |
| `ram.vector_store_growth_mb` | 8.08 MB | Footprint growth for 2,000 vectors + metadata |
| `file.read_300_files_ms` | 6.30 ms | 300 files read from disk (editor open-path proxy) |
| Embeddings: `bge-small-en-v1.5` | 3.2 ms avg | On-device embedding (384-dim, 63 MB) |
| Embeddings: `bge-base-en-v1.5` | 7.4 ms avg | On-device embedding (768-dim, 207 MB) |
| Embeddings: `bge-large-en-v1.5` | 15.0 ms avg | On-device embedding (1024-dim, 636 MB) |

### Reading the RAM numbers honestly

The baseline is the **test-hosted process** (app + XCTest bundle), not a bare app launch — the
absolute number is not the marketing number. The **deltas are the truth**: 8 MB for 2,000
semantic entries, sub-millisecond search. The standalone app's idle footprint is measured
separately on a release build (add `./run.sh app`, sample `phys_footprint`, and report back —
it's a tracked KPI below).

## Why these KPIs

These are the numbers our ICP actually cares about — the ones that made us build Compass:

1. **RAM** — the founding story: *"Cursor + Docker ate my 16GB."* We track footprint and growth
   because bloat is a bug.
2. **Search latency** — RAG quality is worthless if retrieval feels slow. Sub-millisecond at
   2,000 entries; the target is sub-10ms at 1,000,000.
3. **Embedding latency** — the ANE promise. All three bundled models must stay under 100 ms/embedding.
4. **File reads** — the editor's open path. Millisecond-scale for 300 files.

## Thresholds (regression gates)

| Metric | Gate |
|---|---|
| `vector.search_p95_ms` | < 500 ms (current: 0.46) |
| `vector.add_2000_ms` | < 30 s (current: 158) |
| Embedding avg (any model) | < 100 ms (current: 3–15) |
| `file.read_300_files_ms` | < 5 s (current: 6) |

These gates are sanity checks, not marketing. A regression that triples search latency should
fail the build — that's the point of having benchmarks in CI.

## Next KPIs (roadmap)

| KPI | Status |
|---|---|
| **FIM completion latency** (local 4B model, p50/p95) | Next — requires the on-device model; runs locally, gated by `COMPASS_BENCH_FIM=1` |
| **Startup-to-ready** (launch → window usable) | Next — after the app is stable |
| **Index time** (first + incremental, 100k-LOC repo) | Next |
| **Standalone app idle RAM** (Release build) | Tracked manually until the launch flow exists |

## Methodology notes

- All timings use `Date()` wall-clock deltas in-process; search/add are measured over 50/2000
  iterations and reported as percentiles where it matters.
- The vector store uses the production `VectorStoreService` with the real FAISS C bridge
  (`IDMap,HNSW32`, 64-dim, deterministic test vectors).
- Machine-dependent absolute values are expected to vary; **deltas and percentiles are the
  comparable numbers**. CI runs on GitHub-hosted arm64 (`macos-14`).
