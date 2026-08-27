# Local Inference Memory, Context, and Residency Specification

**Status:** Approved for implementation  
**Scope:** Live MLX chat/agent inference path. Harness changes follow after
production behavior is stable.

## Objective

Make local Qwen3.5-4B inference reliable and fast on a 16 GB M4 while
preserving the model's full 262,144-token capability for users on hardware
that can use it. The context slider remains the sole user-facing context
policy: it defaults to 65,536 tokens, may be reduced, and may be extended to
262,144 tokens.

The setting is a maximum request envelope, not a promise to retain an
unbounded raw transcript in every subsequent request.

## Non-goals

- Do not lower the model's 262,144-token advertised maximum.
- Do not reduce the normal 4,096-token response allowance merely to avoid a
  memory bug.
- Do not create a parallel local inference pipeline or duplicate the agent
  harness's application logic.
- Do not update the MLX vendor package as a substitute for fixing Compass's
  ownership and budgeting policy.

## Design

### Exact request envelope

Every request must satisfy:

```
rendered system + tools + explicit context + retained messages + max output
    <= configured context length
```

The allocator uses tokenizer counts when the tokenizer is available. It keeps
tool-call/result exchanges atomic and retains the newest complete exchanges
that fit. Older exchanges are deliberately excluded from the raw transcript.
The first implementation projects the newest raw exchanges and rejects a
single oversized request rather than silently truncating it. The next tracked
phase replaces omitted raw exchanges with an explicit durable-state
compaction checkpoint (task goal, completed work, changed files, decisions,
and unresolved blockers). That checkpoint is generated through the existing
agent pipeline and appended to the canonical conversation; it is not a second
inference path.

Before generation, the native generator validates the rendered prompt plus
the requested output reservation. Violations fail closed before GPU work.

### KV cache policy

- Qwen3.5-4B uses 4-bit attention KV by default. Model-weight quantization and
  KV quantization are distinct; both are required for a small long-context
  footprint.
- The strict request envelope is the initial bound for QuantizedKVCache. The
  vendor implementation prioritizes its unbounded quantized cache over the
  rotating cache, so `maxKVSize` alone is not a memory boundary.
- Changing context length, KV precision, model, or prompt/tool schema
  invalidates resident and persisted KV caches.
- Retain one resident conversation KV cache. Prefix cache persistence remains
  available for fast new-conversation startup; complete conversation state is
  not retained for multiple inactive conversations.

### Model residency

Chat/agent inference has foreground priority. FIM is an idle-time accelerator,
not a peer workload:

1. Before chat preload or generation, unload resident FIM containers.
2. FIM continues to load lazily when the editor requests a completion.
3. The existing global MLX inference lock remains the sole execution
   serialization mechanism.
4. Memory-pressure eviction remains a fallback, not the normal coordinator.

RAG is not an MLX language-model container in this application. Its FAISS
store and CoreML embedding work are outside this chat/FIM residency policy.

### Unload contract

An unload that claims to release chat inference memory must:

1. Synchronize the MLX stream.
2. Persist requested conversation state first.
3. Clear every resident `PromptCacheEntry` and its LRU bookkeeping.
4. Drop model containers/in-flight loads.
5. Clear MLX allocator cache.

Persisted conversation caches may be restored later, but no MLX arrays may be
retained by the generator after the unload returns.

## Implementation sequence

1. Correct cumulative prompt budgeting and add native preflight validation.
2. Enable 4-bit KV by default and reduce resident conversation cache capacity
   to one.
3. Correct chat unload cleanup and cache invalidation conditions.
4. Add foreground chat-to-FIM residency handoff.
5. Emit prompt-budget and resident-cache telemetry.
6. Add durable-state compaction checkpoints through the existing agent path.
7. Add focused unit tests, then adapt the harness for deterministic lifecycle
   cleanup and long-context profiling.

## Acceptance criteria

- A 64K setting is honored as a hard maximum request envelope while retaining
  a 4K completion reservation.
- A 262K setting remains selectable and is passed through without a lower
  application clamp.
- No raw-history growth can make a prompt exceed its configured envelope.
- A critical unload releases resident conversation KV arrays, not only model
  containers and allocator cache.
- Starting chat inference evicts FIM before Qwen is loaded or generated.
- Trace telemetry identifies prompt budget, retained history, KV precision,
  resident cache count, and eviction reason.
