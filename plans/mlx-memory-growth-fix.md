# MLX Memory Growth & Slowdown Fix

## Problem
The MLX inference system exhibited two symptoms during extended use:
1. **Progressive slowdown** - each turn took longer than the previous
2. **Indefinite memory growth** - Metal GPU memory kept growing without bound

## Root Cause Analysis

### Primary Causes

1. **Unbounded Metal Buffer Pool** (`LocalModelProcessAIService.swift`)
   - MLX uses a Metal buffer recycling pool that grows but never shrinks by default
   - Each generation allocates GPU memory for KV cache arrays and intermediate computations
   - Without `Memory.cacheLimit`, the pool grows to several GB over long sessions
   - The `Memory.clearCache()` API exists but was never called between generations

2. **Growing Conversation History = Growing Input Size** (`ToolLoopHandler.swift`)
   - Each tool loop iteration sent `historyCoordinator.messages` (full history) to the model
   - Tool results (file contents, command outputs) were stored verbatim - often thousands of characters
   - As conversation grew, input token count grew proportionally
   - Longer input = longer prefill time + larger KV cache per generation

3. **No KV Cache Size Cap** (`LocalModelProcessAIService.swift`)
   - `GenerateParameters` only set `maxTokens` but not `maxKVSize`
   - This used `KVCacheSimple` (unbounded) instead of `RotatingKVCache` (bounded)
   - Each generation's KV cache grew proportionally to input length with no cap

### Secondary Causes

4. **ConversationPlanStore unbounded cache** (`ConversationPlanStore.swift`)
   - Plans cached by conversationId with no eviction policy
   - Over many conversations, the in-memory dictionary grew indefinitely

## Fixes Implemented

### Fix 1: MLX Memory Management (`LocalModelProcessAIService.swift`)
- **Set `Memory.cacheLimit` to 256 MB** on `NativeMLXGenerator` init to cap the Metal buffer pool
- **Set `maxKVSize = contextLength`** in `GenerateParameters` to use `RotatingKVCache` instead of unbounded `KVCacheSimple`
- **Call `Memory.clearCache()`** after every generation to release unused Metal buffers
- **Added memory observability logging** every 5 generations (active/cache/peak MB)

### Fix 2: Message Truncation (`MessageTruncationPolicy.swift`)
- New `MessageTruncationPolicy` enum with two-phase truncation:
  - **Phase 1**: Truncate individual tool results exceeding 2,000 characters
  - **Phase 2**: If total message characters exceed 12,000, aggressively truncate tool results to 500 chars
- Applied in `ToolLoopHandler` before sending follow-up messages to the model
- Only tool/tool-execution messages are truncated; user/assistant/system messages are preserved

### Fix 3: ConversationPlanStore LRU (`ConversationPlanStore.swift`)
- Added LRU eviction with `maxCachedPlans = 5`
- `accessOrder` array tracks usage; oldest entries evicted when cache exceeds limit
- Plans still persist to disk, so evicted entries are re-read on cache miss

### Fix 4: MLX Package Dependency (`project.pbxproj`)
- Added `mlx-swift` as a direct package reference to access `Memory` API
- Added `MLX` as a package product dependency for the main target

## Testing

### Unit Tests
- `MessageTruncationPolicyTests.swift` - 8 tests covering truncation behavior
- `ConversationPlanStoreLRUTests.swift` - 2 tests covering LRU eviction

### Harness Test
- `testHarnessMemoryStabilityAcrossTurns` - 4-turn test validating:
  - Message count stays bounded (< 60) via conversation folding
  - Files are created successfully across turns
  - Memory snapshots logged per turn for observability

## Files Modified
- `compass/Services/LocalModels/LocalModelProcessAIService.swift` - MLX memory fixes
- `compass/Services/ConversationFlow/ToolLoopHandler.swift` - Message truncation integration
- `compass/Services/ConversationFlow/MessageTruncationPolicy.swift` - NEW: truncation policy
- `compass/Services/Planning/ConversationPlanStore.swift` - LRU eviction
- `compass.xcodeproj/project.pbxproj` - MLX package dependency
- `compassHarnessTests/AgenticHarnessTests.swift` - Memory stability test
- `compassTests/MessageTruncationPolicyTests.swift` - NEW: unit tests
- `compassTests/ConversationPlanStoreLRUTests.swift` - NEW: unit tests
