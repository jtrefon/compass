# KV Cache Implementation Strategy

## Executive Summary

This document outlines the implementation strategy for KV cache optimization in the MLX local inference system.

**Note on Model Cache Sizing:** The current `maxCachedModels = 1` is correct and should remain. We only use one model at a time, and caching multiple models would consume excessive RAM causing system swap. This strategy focuses on **KV cache for conversation turns**, not model caching.

## Current Architecture Analysis

### Model Container Caching (Current State - CORRECT)

```
NativeMLXGenerator (actor)
├── containersByModelDirectory: [URL: ModelContainer]
├── accessOrder: [URL]  // LRU tracking
└── maxCachedModels = 1  // CORRECT - single model only
```

**This is correct behavior** - we only need one model in memory at a time.

### Generation Flow (Current State)

```
generate(modelDirectory, prompt, runId, contextLength)
├── loadContainerCached() → ModelContainer
├── UserInput(chat: [.user(prompt)])
├── container.perform { context in
│   ├── context.processor.prepare(input: userInput)  // Tokenizes FULL prompt
│   └── MLXLMCommon.generate(input, parameters, context)  // Generates tokens
└── Stream output chunks
```

**Problem:** Each request re-encodes the entire conversation history, including:
- System prompt (same every turn)
- Tools definition (same every turn)
- Previous conversation messages (grows each turn)

---

## Strategy: KV Cache Persistence

### Complexity: HIGH
### Impact: HIGH (40-60% for multi-turn conversations)

### Challenge Analysis

The MLX framework's public API (`MLXLMCommon.generate()`) handles KV cache internally but does not expose it for persistence. Investigation needed:

1. **MLX Framework API Investigation Required**
   - Check if `ModelContext` exposes KV cache state
   - Check if `generate()` accepts pre-computed cache
   - May require filing feature request with mlx-swift-lm team

2. **Alternative: Prompt Prefix Caching**
   - Cache tokenized system prompt + tools
   - Reuse for subsequent requests
   - Lower impact but more feasible with current API

### Implementation Plan (Phased Approach)

#### Phase 1: Prompt Prefix Caching (Feasible Now)

```swift
// New file: compass/Services/LocalModels/PromptPrefixCache.swift

actor PromptPrefixCache {
    private var cachedPrefixes: [String: CachedPrefix] = [:]
    
    struct CachedPrefix: Sendable {
        let tokenCount: Int
        let conversationId: String
        let systemPrompt: String
        let toolsHash: String
        let timestamp: Date
    }
    
    func getCachedPrefix(
        conversationId: String,
        systemPrompt: String,
        tools: [AITool]?
    ) -> CachedPrefix? {
        let key = cacheKey(conversationId: conversationId, systemPrompt: systemPrompt, tools: tools)
        return cachedPrefixes[key]
    }
    
    func storePrefix(
        conversationId: String,
        systemPrompt: String,
        tools: [AITool]?,
        tokenCount: Int
    ) {
        let key = cacheKey(conversationId: conversationId, systemPrompt: systemPrompt, tools: tools)
        cachedPrefixes[key] = CachedPrefix(
            tokenCount: tokenCount,
            conversationId: conversationId,
            systemPrompt: systemPrompt,
            toolsHash: hashTools(tools),
            timestamp: Date()
        )
    }
    
    private func cacheKey(conversationId: String, systemPrompt: String, tools: [AITool]?) -> String {
        // Create stable hash for cache key
    }
}
```

#### Phase 2: Full KV Cache (Requires MLX API Changes)

```swift
// Future implementation - requires MLX framework support

actor ConversationKVCache {
    private var caches: [String: KVCacheState] = [:]
    
    struct KVCacheState: Sendable {
        let conversationId: String
        let modelId: String
        let cachedTokenCount: Int
        let cacheData: Data  // Serialized KV cache
    }
    
    func getCache(for conversationId: String, modelId: String) -> KVCacheState? {
        caches["\(conversationId)_\(modelId)"]
    }
    
    func updateCache(for conversationId: String, modelId: String, cache: KVCacheState) {
        caches["\(conversationId)_\(modelId)"] = cache
    }
    
    func invalidateCache(for conversationId: String) {
        caches.removeValue(forKey: conversationId)
    }
}
```

### Integration Points

1. **LocalModelProcessAIService.sendMessage()**
   - Check for cached prefix before building full prompt
   - Pass conversationId to generator

2. **NativeMLXGenerator.generate()**
   - Accept optional conversationId parameter
   - Check for existing cache
   - Update cache after generation

3. **ChatHistoryCoordinator**
   - Invalidate cache when conversation changes
   - Track conversation turn count

### Files to Create/Modify
1. Create `compass/Services/LocalModels/PromptPrefixCache.swift`
2. Modify `compass/Services/LocalModels/LocalModelProcessAIService.swift`
3. Future: Create `compass/Services/LocalModels/ConversationKVCache.swift`

---

## Implementation Priority

### Phase 1 (Immediate)
1. ✅ Prompt Prefix Caching - Medium complexity, moderate benefit
2. ✅ Performance Metrics in Harness - Diagnostic value

### Phase 2 (After MLX API Investigation)
3. Full KV Cache Persistence - High complexity, high benefit
4. Speculative Decoding - Research required

---

## Testing Strategy

### Unit Tests
- `PromptPrefixCacheTests` - Cache key generation, storage, retrieval

### Integration Tests
- Multi-turn conversation performance
- Cache invalidation on conversation change

### Harness Tests
- Add performance metrics to `AgenticHarnessTests`
- Track tokens/second, time-to-first-token
- Compare before/after optimization

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| MLX API doesn't expose KV cache | Medium | High | Start with prompt prefix caching |
| Cache invalidation bugs | Medium | Medium | Comprehensive test coverage |
| Performance regression | Low | High | Benchmark before/after |

---

## Next Steps

1. **Implement Prompt Prefix Caching** (Code mode)
   - Create `PromptPrefixCache.swift`
   - Integrate with `LocalModelProcessAIService`
   - Add tests

2. **Add Performance Metrics to Harness** (Code mode)
   - Instrument `AgenticHarnessTests`
   - Add timing measurements
   - Create performance baseline

3. **Research MLX KV Cache API** (Future)
   - Review mlx-swift-lm source code
   - File feature request if needed
   - Prototype full KV cache solution
