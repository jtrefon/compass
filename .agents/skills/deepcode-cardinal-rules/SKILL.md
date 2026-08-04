---
name: deepcode-cardinal-rules
description: Cardinal rules for the Compass project. Use when writing, reviewing, or architecting code to avoid common LLM coding mistakes. Covers harness-vs-app separation, dead code detection, and build-first discipline.
---

# DeepCode Cardinal Rules

These rules MUST be followed in every session. Violations cause cascade failures.

## Rule 1: Harness Orchestrates — Never Implements

**The harness (test/verification code) calls production code. It never replaces it.**

```
✅ CORRECT: harness.swift
   let tool = ReadFileTool(...)        // production AITool
   let result = try await tool.execute(args)
   XCTAssert(result.contains("content"))

❌ WRONG: harness.swift
   func readFile(path: String) -> String {
       return FileManager.default.contents(atPath: path)  // reimplementing tool logic
   }
```

**Checklist before writing harness code:**
- [ ] Does this logic already exist in the app target? If yes, CALL it, don't reimplement.
- [ ] Am I creating a mock that replaces app behavior? Mocks are only for external dependencies (network, filesystem, AI service).
- [ ] Is the harness creating its own `ToolDefinition` or `AITool`? Use the production ones.

**Penalty:** Any harness code that duplicates app logic must be deleted and rewritten to call the app code.

## Rule 2: Build Before Claiming Progress

**Every change must compile before the next change is started.**

```
❌ WRONG:
   Change file A → Change file B → Change file C → Build → FAIL (3x debugging)

✅ CORRECT:
   Change file A → Build → Change file B → Build → Change file C → Build
```

**Exception:** Documentation, markdown, and prompt files don't need compilation checks.

## Rule 3: Dead Code Must Be Identified, Not Just Created

**Before creating new code, inventory what already exists.**

When asked to "fix mode X" or "add feature Y":
1. Search for all files that reference the mode/feature
2. Trace the runtime path (who calls what)
3. Identify dead vs live code
4. Report findings before implementing

**Test for dead code:** If a file has ZERO references from outside its directory subtree, it is dead.

## Rule 4: One Production Path — One Working Path

**There must never be two competing implementations of the same concern.**

```
❌ WRONG:
   Services/Tooling/ToolExecutor.swift  (new, broken)
   Services/AIToolExecutor.swift        (old, working)

✅ CORRECT:
   Keep one working path. The other is either deleted or clearly marked as PHASE 2+.
```

When a duplicate exists:
1. Route the new feature through the WORKING path
2. Mark the dead code with a header comment: `// PHASE 2+ — NOT ON RUNTIME PATH`
3. Do NOT attempt to fix both paths simultaneously

## Rule 5: Trace the Telemetry Before Diagnosing

**When something doesn't work, look at what the system ACTUALLY did — not what you think it did.**

1. Run the failing scenario
2. Check `ai-trace.ndjson` — was the AI called? With what tools?
3. Check `app.ndjson` — were there errors?
4. Check `crash.ndjson` — did it crash?
5. Check the session JSON — what mode was active? What messages exist?

Only after telemetry analysis, make code changes.
