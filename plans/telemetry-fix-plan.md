# Telemetry Fix Plan

## Problem Statement

Current telemetry system writes to multiple locations including `~/Library/Application Support/compass/Logs/` which causes:
- Cross-project pollution and data corruption
- Impossible to debug per-project issues
- Redundant I/O (writing to both locations)

## Current Architecture Issues

### 1. Multiple Redundant Logging Systems

| Logger | App Support | Project Root | Status |
|--------|-------------|--------------|--------|
| AppLogger | ✅ BOTH | ✅ | DUPLICATE |
| CrashReporter | ✅ BOTH | ✅ | DUPLICATE |
| AIToolTraceLogger | ❌ ONLY | ❌ NONE | **MISSING** |
| ConversationLogStore | ✅ BOTH | ✅ | DUPLICATE |
| ConversationIndexStore | ✅ BOTH | ✅ | DUPLICATE |
| IndexLogger | ❌ NONE | ✅ | OK |

### 2. Key Problems

1. **AIToolTraceLogger has NO project root** - The most critical debug log for AI agent issues doesn't support project isolation!
2. **All loggers write to Application Support** - Causes cross-project pollution
3. **Duplicate writes** - Every log message is written twice (wasteful)
4. **Inconsistent naming** - `.ndjson`, `.log`, `.jsonl`
5. **Dated folders** - AppLogger/CrashReporter create `{date}/` subfolders making navigation harder

## Fix Plan

### Step 1: Fix AIToolTraceLogger (CRITICAL)
**File**: `compass/Services/AIToolTraceLogger.swift`

Add project root support similar to AppLogger:
- Add `setProjectRoot()` method
- Write to `{projectRoot}/.ide/logs/ai-trace.ndjson`
- Remove Application Support write

### Step 2: Fix ConversationScopedNDJSONStore  
**File**: `compass/Services/Logging/ConversationScopedNDJSONStore.swift`

- Remove Application Support path (keep only project path)
- Fix `conversationDirectory()` to use project root

### Step 3: Fix ConversationIndexStore
**File**: `compass/Services/Logging/ConversationIndexStore.swift`

- Remove Application Support write
- Keep only project write

### Step 4: Fix AppLogger (optional cleanup)
**File**: `compass/Services/Logging/AppLogger.swift`

- Remove Application Support write (keep only project)
- Remove dated folder structure

### Step 5: Fix CrashReporter (optional cleanup)
**File**: `compass/Services/Errors/CrashReporter.swift`

- Remove Application Support write (keep only project)
- Remove dated folder structure

## Target Directory Structure

```
{PROJECT_ROOT}/.ide/logs/
├── app.ndjson           # General app logs
├── crash.ndjson         # Crash reports
├── ai-trace.ndjson      # AI tool traces (NEW location!)
├── indexing.log         # Indexing operations
└── conversations/
    ├── index.ndjson     # Conversation metadata
    └── {conversationId}/
        └── conversation.ndjson  # Per-conversation logs
```

## Value for Debugging

| Log File | Contents | Debug Value |
|----------|----------|-------------|
| ai-trace.ndjson | Tool loop iterations, stalls, AI requests | **HIGH** - Agent behavior |
| app.ndjson | General app operations | MEDIUM |
| crash.ndjson | Errors and failures | HIGH |
| conversations/* | Per-conversation message history | HIGH |
| indexing.log | RAG/index operations | MEDIUM |

## Files to Modify

1. `compass/Services/AIToolTraceLogger.swift` - ADD project root support
2. `compass/Services/Logging/ConversationScopedNDJSONStore.swift` - REMOVE app support
3. `compass/Services/Logging/ConversationIndexStore.swift` - REMOVE app support
4. `compass/Services/Logging/AppLogger.swift` - REMOVE app support (optional)
5. `compass/Services/Errors/CrashReporter.swift` - REMOVE app support (optional)

## Implementation Order

1. AIToolTraceLogger (highest impact)
2. ConversationScopedNDJSONStore  
3. ConversationIndexStore
4. AppLogger + CrashReporter (optional cleanup)
