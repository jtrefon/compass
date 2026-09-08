# Mission Control — Intent-Protected Agent Memory

> **Version:** 1.0
> **Status:** Specification — not yet implemented
> **Principle:** Turn the context constraint from a weakness into a structural advantage that makes the agent think like an expert.
> **Scope:** Both local (MLX) and cloud (OpenRouter) pipelines. Local optimizes for footprint; cloud optimizes for efficiency. Shared core, path-specific eviction.
> **Net delta:** ~8 files created, ~4 files modified, ~2 files replaced.

---

## Table of Contents

| Document | Title | Content |
|---|---|---|
| [00-overview.md](00-overview.md) | Overview | Problem statement, architecture summary, design principles (this file) |
| [01-architecture.md](01-architecture.md) | Three-Tier Memory Architecture | Protected / Working / Cold storage tiers, data flow diagrams, KV cache strategy |
| [02-mission-control.md](02-mission-control.md) | Mission Control Block | Structure, injection point, rendering, context budget display |
| [03-note-tool.md](03-note-tool.md) | Note Tool & Working Memory | `NoteTool` spec, `WorkingMemoryStore`, intent tagging (finding vs edit_target) |
| [04-npu-semantic-layer.md](04-npu-semantic-layer.md) | NPU Semantic Intelligence | `SemanticCompressor`, extractive compression, dedup, smart retrieval, clustering |
| [05-eviction-and-reset.md](05-eviction-and-reset.md) | Eviction & Controlled Reset | Note-aware eviction, controlled context reset, budget triggers, KV handling |
| [06-prompt-engineering.md](06-prompt-engineering.md) | Prompt Engineering | Context discipline prompt, mode-coder changes, conservation guidance |
| [07-implementation-plan.md](07-implementation-plan.md) | Implementation Plan | Phased rollout, file list, testing strategy, migration path |

---

## 1. Problem Statement

### The symptom

When the agent reviews a WordPress plugin, it consumes ~40K tokens just to understand the codebase — before taking any action. On a 30K context window (the default for Qwen3.5-4B on machines with moderate RAM), the agent is out of tokens before it can produce the review. On larger machines (up to 262K via the settings slider), the same inefficiency wastes tokens and money but doesn't hit the wall as fast.

### The root cause

The agent has **no working memory**. Every tool result (file reads, search results, bash output) accumulates in conversation history verbatim and is replayed in full on every subsequent model call. There is no compaction, no summarization, no eviction of stale reads. The agent keeps every file it has ever read open in its "brain" forever.

### Current architecture failures

| Failure | Location | Impact |
|---|---|---|
| System prompt cannibalization | `LocalModelPromptBuilder.budgetMessages:183-187` | As tool results accumulate, the system prompt (instructions, tool guidance, mode rules) is truncated to make room. The model loses its operating instructions so stale tool output can stay. |
| No compaction/summarization | `PipelineProcessor` (drops wholesale), `ChatHistoryCoordinator` (no summarize path) | Old tool results are never summarized before eviction. The model loses all memory of dropped work. |
| Count-based eviction (500 messages) | `ChatHistoryCoordinator.maxCommittedCount = 500` | A few huge tool outputs blow the token budget long before 500 messages. The count metric is the wrong unit for context pressure. |
| `preservesCache` inconsistency | `LocalModelToolLoop:92-97` | Local tool-loop iterations don't propagate `preservesCache: true`, causing different truncation behavior between iteration 0 and 1+. |
| KV cache invalidated every turn | `LocalModelPromptBuilder.budgetMessages` | System prompt truncation changes the prefix every turn, flushing the entire KV cache. The `preservesCache = true` flag is defeated by the back-door truncation. |

### What we tried and removed

Token limits on tool output were tried and removed because they corrupted tool calls and code generation. The model would truncate its own tool-call markup mid-call when hitting output caps. This spec does NOT reintroduce output caps. Instead, it manages context at the **history accumulation layer**, not the per-tool output layer.

---

## 2. Solution Summary

### Mission Control

A dynamic block injected as the **last user message** before the model generates. It contains:

1. **Goal + Value** — what we're achieving and why (from existing `TaskPlan`)
2. **Plan + Progress** — task checklist with completion status (from existing `TaskPlan`)
3. **Working Memory** — the model's own structured findings, written via a new `note` tool
4. **Key Excerpts** — NPU-selected relevant code chunks from raw tool results
5. **Context Budget** — live token usage with adaptive conservation guidance

Mission Control is **protected** — it is the last thing evicted, and on the local path it is placed as the final user message so it never invalidates the KV cache prefix.

### The `note` Tool

The model writes its own compressed memory in real time. After reading a file, it calls `note()` with a compact finding. The note is stored in `WorkingMemoryStore` (actor, conversation-scoped, persisted to `.ide/working-memory/`). Notes survive context resets; raw tool results do not.

Intent tagging (`finding` vs `edit_target`) makes compression agent-aware:
- `finding` — code read to understand → raw read becomes disposable after noting
- `edit_target` — code read for editing → raw read is preserved through context resets

### NPU Semantic Intelligence

The existing `bge-small-en-v1.5` embedding model (CoreML, running on NeuralEngine) is elevated from passive embedding generation to an active semantic intelligence layer that runs **in parallel** with LLM generation:

1. **Extractive compression** — selects most relevant code chunks from raw tool results, scored against the current task
2. **Semantic deduplication** — catches redundant notes
3. **Smart retrieval** — scores evicted tool results for relevance during context resets
4. **Note clustering** — organizes Mission Control rendering by semantic topic
5. **Information density scoring** — metacognitive feedback on note quality

Zero LLM tokens consumed. Zero GPU/CPU contention. The NPU and GPU work in parallel.

### Controlled Context Reset

Instead of progressive system-prompt cannibalization (which invalidates KV every turn), the local path does periodic **controlled resets**: one intentional full-prefill when context exceeds 75% capacity. The fresh context is rebuilt from Mission Control + edit_target reads + recent results. Knowledge is preserved in notes; raw reads are evicted. One prefill cost (~2-3s) vs the current death-by-a-thousand-truncations.

---

## 3. Design Principles

1. **The model is an active participant in its own memory management.** It writes notes, declares intent, and watches its context budget. It is not a passive consumer that fills up and breaks.

2. **Intent is protected.** Goal, plan, progress, and working memory live in Mission Control — the last thing evicted, never corrupted by token pressure.

3. **Compression is agent-aware.** The model decides what to note and whether the raw read is disposable (`finding`) or must be preserved (`edit_target`). The system doesn't guess.

4. **The NPU does the heavy lifting.** Extractive compression, dedup, retrieval scoring — all run on the NeuralEngine in parallel with LLM generation. Zero context tokens, zero GPU contention.

5. **KV cache is respected.** Mission Control is the last user message, not part of the system prompt prefix. The system prompt stays byte-identical across turns. Controlled resets are intentional and infrequent, not continuous.

6. **No output caps.** The prior approach of capping tool output corrupted tool calls and code generation. This spec manages context at the history layer, not the per-tool output layer.

7. **Dynamic context awareness.** No hardcoded context sizes. The system reads the configured context length (30K to 262K via slider) and adapts conservation guidance accordingly.

8. **Both paths share the core.** `NoteTool`, `WorkingMemoryStore`, `MissionControlBuilder`, `SemanticCompressor` are shared. Eviction strategy differs: local uses controlled reset, cloud uses note-aware front eviction.

---

## 4. Target Architecture (summary)

```
┌──────────────────────────────────────────────────────────┐
│  PROTECTED CONTEXT (never evicted)                        │
│                                                            │
│  [System Prompt — STABLE, KV cached]                      │
│    Instructions, tool guidance, mode rules, pinned rules  │
│                                                            │
│  [Historical Messages — append-only, KV cached]           │
│    User messages, assistant responses, tool calls/results │
│                                                            │
│  [Mission Control — last user message, rebuilt each turn] │
│    Goal + Plan + Working Memory + Key Excerpts + Budget   │
│    (new each turn — no KV invalidation of prior prefix)   │
└──────────────────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────────────────┐
│  NPU (NeuralEngine) — bge-small-en-v1.5, 384-dim          │
│  Runs IN PARALLEL with LLM on GPU                         │
│                                                            │
│  ▸ Extractive compression of tool results                  │
│  ▸ Semantic deduplication of notes                         │
│  ▸ Smart retrieval scoring for context resets              │
│  ▸ Note clustering for Mission Control rendering           │
│  ▸ Information density scoring                             │
└──────────────────────────────────────────────────────────┘
                    │ embeddings
                    ▼
┌──────────────────────────────────────────────────────────┐
│  COLD STORAGE (unlimited, RAG-accessible)                 │
│                                                            │
│  ▸ All tool result chunks with embeddings (FAISS)         │
│  ▸ All note versions with embeddings                       │
│  ▸ All evicted conversation turns                          │
│  ▸ Retrieval via context() tool (already exists)           │
└──────────────────────────────────────────────────────────┘
```

Detailed architecture in [01-architecture.md](01-architecture.md).

---

## 5. Expected Outcome

| Scenario | Current | With Mission Control |
|---|---|---|
| WordPress plugin review (30K context) | 40K tokens consumed exploring → out of context before acting | 8K tokens (notes + excerpts) → 22K free to write the review |
| Multi-file refactor (30K context) | System prompt cannibalized after ~10 reads → model loses instructions | Controlled reset at 75% → fresh context with full instructions + notes |
| Large codebase exploration (262K context) | 200K+ tokens of raw reads → expensive, slow, unfocused | 20K of notes + excerpts → focused, fast, cheap |
| Repeated file reads | Full re-read each time → context bloat | Notes prevent re-reads; surgical `read(start_line:X, end_line:Y)` only |
| Context reset recovery | All memory lost | Mission Control preserved → model continues seamlessly |

---

## 6. Documents in This Spec

See the Table of Contents at the top of this file. Each document covers one subsystem in implementation-ready detail.
