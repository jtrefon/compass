# Provider Context & Prompt-Caching Research (Reference)

> Audience: compass engineering. Purpose: offline quick-reference for how each
> inference provider handles context windows and prompt caching, and what our
> conversation-context design must do to stay cache-friendly across all of them.
> Compiled: 2026-07-10. Verified against provider docs as of that date.

## 0) The one invariant that drives everything

**Cache hits require an exact-match stable prefix.** Every provider keys its
cache off the opening bytes of the rendered prompt:

- **Anthropic**: prefix must be byte-identical up to each `cache_control`
  breakpoint, or the entire downstream cache misses.
- **OpenAI**: caches the longest matching prefix automatically.
- **OpenRouter**: sticky routing hashes the *first system* + *first non-system*
  message to pin a conversation to one endpoint — so the opening system block
  must be byte-stable per conversation.

Consequence for us: **the system prompt + tool definitions block must be
identical on every request of a session, and must never vary by stage.** Our
current `SystemPromptAssembler` violates this (it injects
`AIRequestStage.reasoningPromptIfNeeded` into the system block), which is the
primary cause of cache invalidation and the 60s timeouts we see against Kilo.

---

## 1) Anthropic (Claude)

- Mechanism: explicit `cache_control: { type: "ephemeral", ttl: "5m" | "1h" }`
  on content blocks.
- **Max 4 breakpoints per request.**
- Prefix cache: exact match up to the breakpoint. Any change anywhere in the
  prefix invalidates everything after it.
- **Default TTL is 5 minutes** (changed from 1h on 2026-03-06). `1h` available
  at 2x write cost.
- Minimum cacheable chunk: **1024 tokens** for Sonnet/Opus, **2048** for Haiku.
- Changing `tool_choice` or adding/removing images anywhere in the prompt
  invalidates the cache.
- Usage fields: `cache_read_input_tokens`, `cache_creation_input_tokens`.
- Pricing: write 1.25x (5m) / 2x (1h); read 0.1x.
- Recommended layout: system block (breakpoint 1) → tool defs (breakpoint 2) →
  static context (breakpoint 3) → recent history. Stable content at front,
  volatile at back.

## 2) OpenAI

- Mechanism: **automatic** prefix caching, no code changes required for
  gpt-4o and newer.
- Minimum: **1024 tokens**; caches longest matching prefix in 128-token
  increments.
- Discount: 50% (GPT-4o) up to ~90% (gpt-5.x).
- TTL: typically 5–10 min of inactivity, removed within 1h.
- `prompt_cache_key` (replaces `user`) keeps cache routing stable across turns.
- `prompt_cache_retention: "24h"` enables extended retention for GPT-5.x+ and
  selected models.
- Newer (GPT-5.6+): explicit `prompt_cache_breakpoint: { mode: "explicit" }`
  on content blocks; `prompt_cache_options.ttl: "30m"` (default).
- Usage: `usage.prompt_tokens_details.cached_tokens`.
- Implication: a **stable prefix is sufficient** — automatic caching does the
  rest. No forced breakpoints needed.

## 3) OpenRouter

- Passthrough to underlying providers.
- **Anthropic models**: support explicit per-block `cache_control` (max 4) or a
  top-level automatic `cache_control`. Explicit recommended for large bodies
  (RAG data, docs, character cards).
- **Responses API** exposes *automatic* caching only (top-level `cache_control`);
  fine-grained per-block breakpoints are NOT exposed via Responses API — use
  Chat Completions or the Anthropic Messages API for breakpoints.
- **Sticky routing**: after a cached request, OpenRouter routes subsequent
  requests for the same model to the same provider endpoint. Conversation
  identity = hash of first system (or developer) message + first non-system
  message. → our opening system block must be byte-stable per conversation.
- Most providers auto-cache; Anthropic/Alibaba need per-message opt-in.
- Usage: `prompt_tokens_details.cached_tokens` / `cache_write_tokens`.
- Pricing multipliers: Anthropic read 0.1x / write 1.25x; DeepSeek read 0.1x;
  Google 0.25x; Grok 0.25x; Moonshot 0.25x; Groq 0.5x.

## 4) Kilo Code

- **Context Condensing / Auto-Compaction**: when the conversation nears
  `compaction.threshold_percent` (or a reserved safety buffer), a compaction
  agent emits an **anchored summary** capturing: overall goal, constraints &
  preferences, progress, key decisions, next steps, relevant files/dirs.
- Keeps the **most recent turns verbatim** when they fit; replaces older
  history with the summary.
- **Delta compaction**: if already compacted, updates the *previous* summary
  instead of restarting (preserves still-relevant detail).
- **Context Pruning** (lighter-weight, runs alongside compaction): tool results
  older than a 40,000-token recency window are replaced with
  `"[Old tool result content cleared]"`.
- Buffer selection: if model advertises a separate input limit, default reserve
  = 20,000 tokens (or model max output, whichever smaller); if only a single
  context window is declared, reserve the model's full output cap (up to
  32,000).
- Routes through OpenRouter / Kilo Gateway; 500+ models.

## 5) OpenCode

- Shares lineage with Kilo (DeepWiki maps Kilo's "Context Window Management"
  into the opencode backend).
- **Session locking during generation**: `SessionRunState` + per-`sessionID`
  `AbortController`; overlapping prompts queued or rejected.
- **Automatic compaction** (summarization + pruning) when context limits
  approach; **session summarization** of codebase effects.
- **Snapshot-based revert/unrevert** for message + filesystem state.
- SQLite-backed persistent sessions; dual **Build vs Plan** agent context
  separation; MCP + LSP integration.

---

## 6) Cross-provider matrix (quick reference)

| Provider | Cache type | Opt-in needed? | Breakpoints | Min tokens | TTL | What we must guarantee |
|---|---|---|---|---|---|---|
| Anthropic | explicit `cache_control` | yes (per block) | ≤4 | 1024 (Haiku 2048) | 5m (1h paid) | stable system+tools prefix; no stage variation; stable `tool_choice` |
| OpenAI | automatic prefix | no | n/a (GPT-5.6+ explicit) | 1024 | 5–10m (24h opt) | stable prefix; set `prompt_cache_key` |
| OpenRouter | passthrough | Anthropic: yes | ≤4 (CC API) | per model | per upstream | stable first system block (sticky hash); `cache_control` on anthropic routes |
| Kilo | auto-compaction + pruning | n/a (agent) | n/a | n/a | n/a | anchored-summary compaction shape; recency-window pruning |
| OpenCode | auto-compaction + pruning | n/a (agent) | n/a | n/a | n/a | same shape; session-scoped locked writes |

---

## 7) Design implications (for the frozen conversation-context work)

1. **Protected prefix.** Seq 0 = system prompt, seq 1 = tool definitions,
   injected at projection time, identical every turn. `SystemPromptAssembler`
   must be made stage-independent; stage-specific reasoning prompts move out of
   the prefix (into the chain as a `.systemText` turn, or after the breakpoint).
2. **Provider adapter.** `ConversationContextStore.projectedContext(for:)`
   returns a provider-neutral `ProjectedContext`; a `ProviderContextAdapter`
   emits the exact wire shape:
   - Anthropic / OpenRouter-anthropic → `cache_control` on system+tool block.
   - OpenAI → stable prefix + `prompt_cache_key` (envelope id).
   - OpenRouter → same `cache_control` for anthropic routes (satisfies sticky
     hash automatically via stable first system block).
   - Kilo / OpenCode → message list they expect (stable system + tools +
     compacted history + recent verbatim turns).
3. **RAG is a tool, not a forced prepend.** Remove the per-turn `context`
   injection in `OpenAICompatibleChatService.buildFinalMessages`; advertise
   `context(query:)` / `web_search` as normal tools. This also removes a second
   cache-killer (the `context` string currently changes every turn).
4. **Two context modes, model-aware:**
   - `compaction` — anchored `.checkpoint` summary (Kilo/OpenCode shape);
     projection folds pre-checkpoint turns; delta-update prior summary.
   - `slidingWindow` (SWA) — keep full immutable chain; recency-window pruning
     + hard-cap head trim only at the absolute limit.
   - `ModelContextProfile` registry maps model id → `{ window,
     supportsPrefixCache, defaultStrategy }`.
5. **Rock-solid abstraction.** Core chain (`ConversationStreamStore` + `Turn`
   with monotonic `seq`) is private. External code touches only
   `ConversationContextStore` (append-only writes, projected reads, `compact`,
   envelope). No remove/replace/update/upsert on chain nodes.
6. **Conversation envelope.** `ConversationEnvelope { id: UUID, subject,
   createdAt, updatedAt }` stored alongside the turn chain — gives traceable
   date + UI title without touching the chain.

## 8) Verification hooks to add

- `PrefixStabilityTest`: assert the system+tool prefix is byte-identical across
  `initial_response → tool_loop → tool_loop → final_response` (FAILS on current
  code).
- `CacheBreakpointEmittedTest`: per-provider adapter, assert `cache_control` /
  stable prefix shape is produced for a representative model of each provider.
- Runtime smoke: long agentic task → request size plateaus (not grows);
  `cache_read_input_tokens` > 0; no 60s timeouts.

## 9) Open questions

- "Support kilo/opencode" interpreted here as **context-shape alignment**
  (our compacted output mirrors their anchored-summary format), since both are
  agent frameworks that ultimately route to Anthropic/OpenAI/OpenRouter rather
  than raw inference endpoints. If we instead proxy inference through Kilo/OpenCode
  APIs, the adapter layer changes but the core abstraction is identical.
- Default strategy selection: large-window + cache models → `slidingWindow`;
  others → `compaction`. May instead be an explicit global user toggle.
