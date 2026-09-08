# 01 — Three-Tier Memory Architecture

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. The Three Tiers

### Tier 1: Protected Context (never evicted)

Everything in this tier is guaranteed to be in every model call. It is the agent's permanent working state.

```
[System Prompt]
  ├── Base system prompt (Prompts/System/base-system-prompt.md)
  ├── Tool reference prompts (Prompts/Tools/v3/*.md)
  ├── Tool execution envelope
  ├── Mode prompt (Prompts/System/mode-coder.md + context discipline section)
  ├── Project shape summary
  ├── Pinned rules
  └── Reasoning directives

[Historical Messages — append-only]
  ├── User messages
  ├── Assistant responses (with reasoning)
  ├── Tool call messages (assistant role, toolCalls)
  └── Tool result messages (tool role)

[Mission Control — last user message]
  ├── Goal + Value
  ├── Plan + Progress
  ├── Working Memory (model-written notes)
  ├── Key Excerpts (NPU-selected code chunks)
  └── Context Budget + conservation guidance
```

**KV cache behavior (local path):**
- System prompt: byte-identical across all turns → KV cached forever
- Historical messages: append-only → KV cached as added, never invalidated
- Mission Control: new each turn, placed as LAST user message → does NOT invalidate prior KV. Only the new tokens need prefill.

**This is the critical insight:** by placing Mission Control at the END of the message list instead of in the system prompt, we get protection (it's the last thing evicted, it's what the model sees right before generating) without KV invalidation.

### Tier 2: Working Context (evictable)

The recent active working set — tool results from the last few turns that the model is actively using.

```
[Last 3-5 tool results]
  ├── Most recent file reads (raw, unmodified)
  ├── Most recent search results
  ├── Most recent bash output
  └── Any edit_target reads (protected until edit completes)

[Current reasoning / response draft]
  └── The model's in-progress generation
```

This tier grows during exploration and is evicted when context pressure increases. Eviction is note-aware: tool results that have been covered by a `finding` note are evicted first; `edit_target` reads are preserved.

### Tier 3: Cold Storage (unlimited, RAG-accessible)

Everything that has been evicted from working context, stored with embeddings for on-demand retrieval.

```
[FAISS Vector Store — .ide/vector_store/]
  ├── All evicted tool result chunks (with embeddings)
  ├── All note versions (with embeddings)
  ├── All evicted conversation turns
  └── Retrieval via context() tool (already exists)

[Working Memory Store — .ide/working-memory/]
  ├── {conversationId}.json — current notes
  ├── {conversationId}.embeddings.json — note embeddings cache
  └── Persists across sessions
```

The model can retrieve from cold storage at any time via the existing `context()` tool. The NPU scores retrieval candidates against the current task for relevance-ranked results.

---

## 2. Data Flow

### Exploration phase (append-only, KV grows)

```
User: "Review my WordPress plugin for security"
  │
  ▼
Agent calls search("plugin entry")
  → SearchProjectTool returns 2K of results
  → Tool result appended to history (Tier 2)
  → NPU: SemanticCompressor.compress() runs in parallel
    → Splits results into chunks
    → Embeds each chunk (NPU, ~5ms/chunk)
    → Scores against task context
    → Selects top-3 key excerpts
    → Stores full results in FAISS (Tier 3)
  │
  ▼
Agent calls read("plugin-entry.php", limit=30)
  → ReadFileTool returns 1.5K
  → Tool result appended to history (Tier 2)
  → NPU: SemanticCompressor.compress() runs in parallel
    → Extracts 2 key excerpts (hook registration, controller)
    → Stores full read in FAISS (Tier 3)
  │
  ▼
Agent calls note(section="architecture", intent="finding",
                 content="3 hooks, controller at L23, delegates to Payment+Notification")
  → NoteTool writes to WorkingMemoryStore
  → NPU: SemanticCompressor.findDuplicateNote() checks for redundancy
  → Mission Control rebuilt with new note (injected as last user message next turn)
  │
  ▼
... repeat for each file ...
  │
  ▼
Context budget monitor: 75% full
  → CONTROLLED RESET triggered
  → See 05-eviction-and-reset.md for reset flow
```

### Execution phase (after reset)

```
[Controlled Reset fires]
  │
  ▼
Fresh context assembled:
  [System Prompt — full, untruncated]
  [Mission Control — goal, plan, all notes, key excerpts, budget]
  [edit_target reads — raw code for pending edits]
  [Last 3-5 tool results — active working set]
  [User message: "Continue from your notes. Context was reset to free space."]
  │
  ▼
Agent works from Mission Control notes
  → Reads specific file:line ranges only when needed (surgical)
  → Makes edits, runs tests
  → Writes results to notes
  → If context fills again → another controlled reset
```

---

## 3. KV Cache Strategy (Local Path)

### Current behavior (broken)

```
Turn 1: [system: 8K] [msgs: 2K] → total 10K → fits → KV cached
Turn 2: [system: 8K] [msgs: 5K] → total 13K → fits → KV extended
Turn 5: [system: 8K] [msgs: 20K] → total 28K → over budget
  → budgetMessages truncates system to 2K → PREFIX CHANGED
  → ENTIRE KV CACHE INVALIDATED → full re-prefill of 22K
Turn 6: [system: 2K] [msgs: 23K] → total 25K → over budget
  → budgetMessages truncates system to 1K → PREFIX CHANGED AGAIN
  → ENTIRE KV CACHE INVALIDATED AGAIN → full re-prefill of 24K
```

**Every turn after the budget is exceeded invalidates the entire KV cache.** The `preservesCache = true` flag prevents message eviction, but system prompt truncation achieves the same invalidation through the back door.

### Proposed behavior

```
Turn 1: [system: 8K] [msgs: 2K] [MC: 1K] → total 11K → fits
  → KV cached for system + msgs. MC is new (last message), prefill 1K.
Turn 2: [system: 8K] [msgs: 5K] [MC: 1.5K] → total 14.5K → fits
  → KV extended for new msgs. MC is new, prefill 1.5K. Prior KV intact.
Turn 5: [system: 8K] [msgs: 20K] [MC: 3K] → total 31K → over budget (75%)
  → CONTROLLED RESET fires
  → Fresh context: [system: 8K] [MC: 5K] [edit_targets: 3K] [recent: 4K] = 20K
  → ONE full prefill of 20K (intentional)
  → KV cache rebuilt from scratch
Turn 6: [system: 8K] [msgs: 2K] [MC: 5.5K] → total 15.5K → fits
  → KV cached for system + msgs. MC is new, prefill 5.5K. Prior KV intact.
Turn 10: [system: 8K] [msgs: 18K] [MC: 6K] → total 32K → over budget again
  → CONTROLLED RESET fires again
  → ONE full prefill
```

**Cost comparison:**
- Current: full re-prefill EVERY turn after budget exceeded (10+ prefills for a 15-turn task)
- Proposed: one full prefill per reset cycle (2-3 prefills for the same task)

**The system prompt is NEVER truncated.** The model always has its full instructions. Knowledge is preserved in Mission Control notes, not in raw tool results.

---

## 4. Cloud Path (No KV Concern)

The cloud path (OpenRouter) is stateless — every request rebuilds from scratch. No KV cache to invalidate. This gives us freedom:

### Cloud eviction strategy: note-aware front eviction

```
Every request:
  1. Assemble full message list from ChatHistoryCoordinator
  2. PipelineProcessor.prepareForRequest() with note-aware eviction:
     a. Keep system messages (head)
     b. Keep Mission Control (injected as last user message)
     c. Keep edit_target tool results (protected)
     d. Keep last 3-5 tool results (active working set)
     e. Evict oldest finding-tagged tool results first
     f. Evict oldest non-noted tool results second
     g. Evict oldest user/assistant messages third
  3. Send to provider
```

The cloud path doesn't need controlled resets — it naturally "resets" every request. The note-aware eviction ensures the most valuable content (Mission Control, edit_targets, recent results) is always retained, and the least valuable (old finding reads) is evicted first.

### Cloud token savings

| Content | Before | After |
|---|---|---|
| 10 file reads (50 lines each) | ~15K tokens | ~3K (notes) + ~2K (key excerpts) = 5K |
| 5 search results | ~5K tokens | ~1K (compressed) |
| 3 bash outputs | ~4K tokens | ~1K (compressed) |
| Total for exploration | ~24K tokens | ~7K tokens |
| **Savings per exploration cycle** | — | **~17K tokens (~70%)** |

At OpenRouter pricing (~$2/M tokens for mid-tier models), this saves ~$0.034 per exploration cycle. Across a day of heavy use (50 cycles), that's ~$1.70/day or ~$50/month.

---

## 5. Shared vs Path-Specific Components

| Component | Shared? | Local behavior | Cloud behavior |
|---|---|---|---|
| `NoteTool` | Shared | Same | Same |
| `WorkingMemoryStore` | Shared | Same | Same |
| `MissionControlBuilder` | Shared | Same | Same |
| `SemanticCompressor` | Shared | Same | Same |
| Eviction trigger | Path-specific | Controlled reset at 75% | Note-aware front eviction every request |
| Mission Control placement | Shared | Last user message (KV-safe) | Last user message (or system prompt) |
| KV cache | Local only | Preserved via append-only + last-message MC | N/A |
| Context budget calc | Shared | Reads `inferenceConfiguration.contextLength` | Reads `ModelContextRegistry` window |

---

## 6. Integration Points

### Where Mission Control is injected

**Local path** (`LocalModelToolLoop`):
After tool results are committed to history, before the next `sendMessageWithRetry` call, Mission Control is appended as a user message:

```swift
// In LocalModelToolLoop.execute(), before aiInteractionCoordinator.sendMessageWithRetry:
let missionControl = await missionControlBuilder.build(
    conversationId: configuration.conversationId,
    contextLength: inferenceConfiguration.contextLength,
    usedTokens: currentTokenEstimate
)
await history.append(ChatMessage(role: .user, content: missionControl))
```

**Cloud path** (`AgentLoop`):
Same pattern — before each `llmCall`, append Mission Control as a user message:

```swift
// In AgentLoop.llmCall(), before aiCoordinator.sendMessageWithRetry:
let missionControl = await missionControlBuilder.build(...)
var messages = messages ?? historyCoordinator.requestMessages
messages.append(ChatMessage(role: .user, content: missionControl))
```

### Where the NPU compressor runs

After every tool result is committed to history, the `SemanticCompressor` processes it in a detached task:

```swift
// After tool results are committed:
Task.detached(priority: .utility) {
    await semanticCompressor.processToolResult(
        result: toolResultContent,
        taskContext: currentTaskContext,
        conversationId: conversationId
    )
}
```

This runs in parallel with the model's next generation. By the time the model finishes generating, the NPU has already compressed the previous tool result, stored it in FAISS, and updated key excerpts.

### Where controlled reset fires (local only)

In `LocalModelToolLoop.execute()`, after each iteration, check the context budget:

```swift
let budget = await missionControlBuilder.computeBudget(
    messages: history.requestMessages,
    contextLength: inferenceConfiguration.contextLength
)
if budget.percentUsed > 0.75 {
    try await performControlledReset(
        history: history,
        conversationId: configuration.conversationId,
        contextLength: inferenceConfiguration.contextLength
    )
}
```

See [05-eviction-and-reset.md](05-eviction-and-reset.md) for the full reset flow.
