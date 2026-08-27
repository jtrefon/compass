# MLX Purge → llama.cpp: Cleanup Proposal

**Branch**: `feature/purge-mlx-llamacpp`
**Date**: 2026-08-10
**Status**: PROPOSAL — awaiting approval before Phase 1 begins

## 1. Verdict

MLX in-process inference is a failed path. It cannot run Qwen3.5-4B on this
class of host without exploding RSS and crashing the app or the system
(mesasured: 6.2 GB @ 32K ctx, 8.4 GB @ 55K, pool-cap thrash, jetsam-grade
failures). Speculative decoding on MLX was a recorded dead end
(`d26f0597`). The sibling project `../llama` (Round 2 harness) verified that
the identical model on llama.cpp **fits the budget**:

| KPI (Qwen3.5-4B Q4_K_M, q4_0 KV) | MLX (Round 1) | llama.cpp (Round 2) |
|---|---|---|
| RSS @ 32K ctx | 6.2 GB | 3.8 GiB |
| RSS @ 55K ctx | 8.4 GB | 3.9–4.0 GiB |
| RSS @ 262K ctx (MTP) | n/a | 7.08 GiB peak, no crash |
| decode @ ≤32K (MTP draft) | 21.3 t/s | 28–30.1 t/s |
| tools / history / NIAH | pass | pass, repeat-tool crack fixed by MTP+thinking |
| failure mode | crash/system kill | throughput collapse only (preflight-gated) |

All llama.cpp measurements: `../llama/docs/ROUND2-LLAMA-REPORT.md` (2026-08-09,
updated 2026-08-10 with MTP §6 and long-context slider §7).

This proposal is a **full purge**: remove the MLX execution stack, the vendored
vendored package, and the remote MLX SPM dependency, then re-point the local
pipeline at a managed `llama-server` child process speaking OpenAI-compatible
HTTP — a protocol this app already has a mature client for.

## 2. What dies (purge list)

### 2.1 Swift files — MLX bindings (delete or replace)

| File | Size | Disposition |
|---|---|---|
| `Compass/Services/LocalModels/NativeMLXGenerator.swift` | 972 L | **DELETE** — MLX ModelContainer engine, KV cache, `LocalModelGenerating` impl. Replacement: `LocalProcessModelService` (llama-server lifecycle) + OpenAI-compatible client |
| `Compass/Services/LocalModels/FIMInferenceService.swift` | 335 L | **DELETE** — MLX FIM. Replacement: `LlamaFIMService` speaking `/v1/completions` (suffix → infill) |
| `Compass/Services/LocalModels/LocalModelPromptBuilder.swift` | 327 L | **DELETE** — prompt/template assembly; llama-server applies the Jinja chat template server-side. Its MLX imports are already unused (vestigial) |
| `Compass/Core/MLXInferenceLock.swift` | 40 L | **DELETE** — serialized the shared in-process GPU allocator. A subprocess is immune to that class of thrash; no lock needed |
| `Compass/Services/LocalModels/TokenIDRecorder.swift` | 43 L | **DELETE** — MLXArray logits processor (in-process sampling gone) |
| `Compass/Services/LocalModels/FIMBannedTokenProcessor.swift` | 46 L | **DELETE** — MLXArray logits processor; banned-token suppression moves server-side (`logit_bias`) |
| `CompassHarnessTests/RawMLXBaselineTests.swift` | 73 L | **DELETE** — raw MLX benchmark, obsolete on all axes |

### 2.2 Keep-shell files (rewrite internals, keep contracts + types)

| File | Change |
|---|---|
| `LocalModelProcessAIService.swift` (552 L) | Keep the `AIService` shell (send/tool-call streaming, pressure handling, registry participation). Swap `NativeMLXGenerator` for the llama server client; drop MLX/MLXLLM/MLXLMCommon/Tokenizers imports |
| `LocalModelCatalog.swift` (80 L) | Keep file/model metadata shape. Replace `mlx-community/*-MLX-4bit` HF repos with GGUF artifact sources (Qwen3.5-4B Q4_K_M + MTP-F16 draft artéfact; Qwen2.5-Coder-1.5B GGUF for FIM). Drop `@preconcurrency import MLXLMCommon` |
| `LocalModelDefinition.swift` (41 L) | Drop unused `MLXLMCommon` import |
| `Core/InferenceUnloadRegistry.swift` (48 L) | **Adapt, not delete**: labels survive; unload hooks become "stop llama-server child" instead of "release MLX containers". FIM-only on warning, everything on critical — policy unchanged |
| `CompletionInferenceService.swift` / `InlineCompletionProviding` (130 L) | Contracts survive; `AIServiceInlineCompletionProvider` resolves `LlamaFIMService` instead of `FIMInferenceService` |
| `Services/AIServicesFactory.swift` | Delete `NativeMLXGenerator.sharedTestGenerator` wiring (tests get a stub server client instead) |

### 2.3 Keep untouched (no MLX anywhere)

`LocalModelDownloader`, `LocalModelFileStore`, `LocalModelInferenceConfiguration`,
`LocalModelSelectionStore`, `LocalModelSettingsKeys`, `LocalModelSettingsViewModel`,
`LocalModelTestBudget`, `LocalModelToolProvider`, `MemoryPressureObserver`,
`UnsafeValue`, `VariantPoolService`, `VariantPoolStore`, `EditorSignalBridge`,
`InlineCompletionSettingsStore`, `InlineCompletionDebugStore`, `ToolMarkupStripper`,
the local tool loop (`executeLocalModelToolLoop`, mode-agnostic), `AIServiceRegistry`
routing, `AgentLoop`/orchestration (unchanged — they talk to `AIService`).

### 2.4 Packages & vendor (delete all three)

1. **`Vendor/mlx-swift-lm/`** — vendored local SPM package (MLXLLM + MLXVLM).
   ~4 MB tracked source; 1.8 GB working dir (ignored `.build`). Full `git rm -r`.
2. **Remote `mlx-swift` SPM dependency** (MLX product) — remove from
   `project.pbxproj` XCLocal/XCRemote refs and `Package.resolved`.
3. **`Tokenizers`** — transitively supplied by the MLX packages only; dies with
   them. No project-level reference exists.

### 2.5 Comment/naming touch-ups (mechanical)

- `AgentActivityCoordinator.swift` — `case mlxInference` → `localInference`
  (activity key `mlx_inference` → `local_inference`; update `isActivityTypeActive`
  caller ~L312).
- `ConversationManager.swift` L135/L683, `ProjectCoordinator.swift` L161,
  `AIServiceProtocol.swift` L7, `GemmaFormatParser.swift` L7,
  `SearchProjectTool.swift` L59 — MLX wording → llama.cpp/local server wording.
- `AGENTS.md` — "Engine live path" local branch: `LocalModelProcessAIService →
  MLX (in-process)` becomes `LocalModelProcessAIService → LlamaServerProcessManager
  → llama-server (child process) → OpenAI-compatible HTTP`.

### 2.6 Doc/plan cleanup (delete after Phase 1 lands)

- `plans/mlx-kv-cache-implementation-strategy.md`
- `plans/mlx-memory-growth-fix.md`
- `plans/speculative_decoding_plan.md`
- `plans/local-inference-architectural-improvements.md` (re-review; may be rewritten, not deleted)

## 3. What comes in (target architecture)

### 3.1 `LlamaServerProcessManager` (new)
- Spawns `llama-server` as a managed child (one model at a time, chat XOR FIM — same
  golden rule as the harness: ONE llama process at a time; FIM and chat can share
  one server since llama-server serves both `/v1/chat/completions` and `/v1/completions`).
- Argument mapping from the existing `LocalModelInferenceConfiguration`:
  `-c <ctx>`, `--cache-type-k/q4_0-v/q4_0`, `--parallel 1`, `-b 1024 -ub 512`,
  `--load-mode mlock`, `--spec-type draft-mtp --spec-type ngram-simple
  --spec-draft-n-max 2` (MTP artifact: `Qwen3.5-4B-Q4_K_M-MTPF16.gguf`).
- **Harness golden rules carried over** (fail at load, not mid-run):
  - explicit `-c` always (262K GGUF default prealloc would jetsam the host),
  - `--parallel 1`,
  - host preflight gate before spawn (free+inactive ≥ 6 GiB equivalent),
  - RSS sampler (limit/kill), port allocation + health-check, graceful SIGTERM.
- `MemoryPressureObserver` integration: .warning → stop FIM-backed shares; .critical
  → kill server process(es) — replace `InferenceUnloadRegistry` hook bodies.

### 3.2 Chat: reuse `OpenAICompatibleChatService`
The local service delegates to the same OpenAI-compatible client the cloud path
uses, pointed at `http://127.0.0.1:<port>/v1`. Streaming, tool calling
(`type: function` — the harness verified tool fidelity 3/3 on the OpenAI-format
tools), thinking blocks, and `logit_bias` are all server-side. `preservesCache:
true` holds because llama.cpp keeps KV in-process per server lifetime.

### 3.3 FIM: `/v1/completions` + `suffix` (or `/infill`) — same
`AsyncThrowingStream<String, Error>` surface; `lastGeneratedFirstTokenID()` keeps
seeding the variant pool's ban set; the ban set ships as `logit_bias`.

### 3.4 Model artifacts & download
- Catalog points at GGUF sources. The llama harness currently builds GGUFs locally
  from HF safetensors (`convert_hf_to_gguf.py` + `--tensor-type` MTP surgery). The
  app's downloader must fetch prebuilt GGUFs — options: (a) publish the two verified
  GGUFs (Q4_K_M + MTP-F16, 2.6/2.95 GiB) to a stable URL and pin hashes; (b) run
  conversion client-side (rejected: torch/transformers dep is heavy). Recommend (a).
- `LocalModelFileStore` layout: `.gguf` file + small sidecar (hash, quant, k/v-quant)
  instead of safetensors directories; checksum verify before accept.

## 4. Phases & verification

| Phase | Work | Verify |
|---|---|---|
| **0** | Branch + this proposal; gitignore `.hermes/*.docx` | `git status` clean except intent |
| **1** | Delete §2.1 files, package refs, Vendor; comment sweep §2.5; `LocalModelProcessAIService` shell kept but generator nil-able → local provider degrades to "no local model" | `./run.sh build` green, `./run.sh test` green; `./run.sh check-prompts` |
| **2** | `LlamaServerProcessManager` + OpenAI client wiring; catalog/file-store/downloader → GGUF; settings mapping | `./run.sh build`; unit tests; manual local chat against a harness-built server |
| **3** | FIM swap + pressure-kill + activity rename + AGENTS.md | `./run.sh test`; FIMBenchmarkHarnessTests against llama server |
| **4** | Harness retarget: local suites run against real llama-server when installed, stub OpenAI-compatible server otherwise; delete dead plans §2.6 | `./run.sh harness-offline`; `./run.sh benchmark-local` (becomes llama benchmark) |

Phase 1 lands atomically as the "purge commit" — the app stays buildable at
every step; between Phase 1 and Phase 2 the local provider simply has no engine
(the UI already handles a missing/misconfigured local model).

## 5. Open questions

1. **GGUF hosting** (3.4a): where do the two verified GGUFs live for download?
   HF repo (preferred) vs GitHub release vs brew tap (`site/brew-tap-*` branches exist).
2. **llama-server binary distribution**: bundled in app Resources vs brew-managed?
   Affects code-signing/notarization and the memory preflight story.
3. **KV disk persistence** (system-prefix KV cache, ~0.3s new-conversation prefill):
   llama.cpp file-backed prompt cache (`--cache-prompt`) support for qwen35 hybrid
   arch is unverified — Phase 2 spike before committing to parity.
4. **FIM model**: Qwen2.5-Coder-1.5B has no verified llama.cpp GGUF in the Round 2
   harness — either convert/publish it or serve FIM from the chat model
   (recommended: verify coder GGUF, it is the FIM-spec fixed model).
5. **Stub server for CI**: harness offline suites need a deterministic OpenAI-
   compatible stub (record/replay of llama-server) so tests run without a model.

## 6. Reference material

- Round 2 (llama.cpp) report + AGENTS golden rules: `/Users/jack/Projects/osx/llama/`
- Round 1 (MLX) report: `/Users/jack/Projects/osx/mlx/docs/ROUND1-MLX-REPORT.md`
- Live-path map (what must stay untouched): root `AGENTS.md` §Engine live path