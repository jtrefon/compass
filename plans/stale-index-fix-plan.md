# Fix Plan: Stale Index Entries Causing File Not Found Errors

## Problem Summary

The agent is trying to delete files with `.js` extensions that don't exist on disk:
- Agent tried: `todo-app/src/App.js`, `index.js`, `reportWebVitals.js`
- Actual files: `App.tsx`, `index.ts`, `reportWebVitals.ts`

**Root Cause**: The index contains stale entries from when the project was JavaScript. After conversion to TypeScript:
1. Old `.js` files were deleted
2. New `.ts/.tsx` files were created  
3. Index still has the old `.js` paths due to faulty "hash match" re-indexing logic

## Indexing Log Evidence

```
[2026-02-20T14:29:46Z] IndexerActor: Processing file todo-app/src/App.js
[2026-02-20T14:29:46Z] IndexerActor: File App.js already indexed (hash match), skipping

[2026-02-20T14:29:46Z] IndexerActor: Processing file todo-app/src/index.js
[2026-02-20T14:29:46Z] IndexerActor: File index.js already indexed (hash match), skipping
```

But on disk:
```
-rw-r--r--  1 jack  staff   272 Feb 20 16:27 App.test.tsx
-rw-r--r--  1 jack  staff   555 Feb 20 16:27 App.tsx
-rw-r--r--  1 jack  staff   553 Feb 20 16:27 index.ts
-rw-r--r--  1 jack  staff   569 Feb 20 16:28 reportWebVitals.ts
```

## Fix Strategy

### Fix 1: Index Should Verify File Exists Before Serving (P0)

Before returning indexed file paths to the model, verify the file actually exists on disk.

**Files to modify:**
- `compass/Services/RAG/CodebaseIndexRAGRetriever.swift` - Add existence check
- `compass/Services/Index/IndexCoordinator.swift` - Add existence validation

### Fix 2: Index Should Clean Up Deleted Files (P1)

The index should detect when files have been deleted and remove their entries.

**Implementation approach:**
- On project open, compare index entries against actual filesystem
- Remove entries for files that no longer exist
- Add telemetry to track stale entry count

### Fix 3: Index Should Use File Discovery Instead of Hash (P1)

Current behavior: Uses file hash to determine if re-indexing needed
Problem: Doesn't detect when files are renamed/moved/deleted

**Implementation approach:**
- On project open, do fresh file discovery
- For each discovered file, check if it's in index
- For each indexed file, check if it still exists on disk

### Fix 4: Tool Execution Should Verify File Exists (P0 - Quick Fix)

Before executing delete_file tool, verify the target file exists.

**Files to modify:**
- `compass/Services/ToolExecutionCoordinator.swift` - Add pre-execution validation
- Return helpful error message: "File 'X' does not exist. Did you mean 'Y.ts'?"

## Priority Order

1. **Fix 4** (Quick): Tool pre-execution validation - prevents agent from trying to delete non-existent files
2. **Fix 1** (Critical): RAG retriever validates paths - prevents wrong paths from reaching model
3. **Fix 2** (Medium): Index cleanup - long-term fix for stale entries
4. **Fix 3** (Long-term): Better indexing strategy

## Telemetry to Add

- `index.stale_entry_detected` - When index returns path that doesn't exist
- `index.entry_removed_due_to_missing_file` - When cleanup removes stale entry
