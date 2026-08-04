# Agentic Toolset & Context Architecture v3

> **Status**: Final Architecture Specification  
> **Goal**: World-class agentic coding IDE. Minimal tool surface, maximum model compliance, zero overlap, fixed-context discipline, RAG-powered retrieval.

---

## Table of Contents

1. [Core Principles](#1-core-principles)
2. [Tool Set](#2-tool-set)
3. [Tool Prompt Templates](#3-tool-prompt-templates)
4. [Context Management](#4-context-management)
5. [RAG Architecture](#5-rag-architecture)
6. [Query → Code Block → Alteration Pipeline](#6-query--code-block--alteration-pipeline)
7. [System Prompt Assembly](#7-system-prompt-assembly)
8. [Classification Sets (ToolTaxonomy)](#8-classification-sets-tooltaxonomy)
9. [Migration Plan](#9-migration-plan)
10. [Files to Create / Modify / Delete](#10-files-to-create--modify--delete)

---

## 1. Core Principles

### 1.1 Tool Principles

| Principle | Rule |
|---|---|
| **One tool per operation** | Exactly one tool for reading, one for editing, one for searching. No aliases, no overlap. |
| **Model-native naming** | Tool names match training data: `read`, `edit`, `bash`, `search`, `glob`, `ls`, `rm`. No compound words, no underscores where avoidable. |
| **Positive advertising** | Tool descriptions explain WHEN to use and WHAT to expect. Never "Do NOT" — always "For X, use Y." |
| **Universal feedback contract** | Every tool returns `status`, `message`, `content` (for queries), `error.code`, `error.recoverable`, `error.alternatives`. |

### 1.2 Context Principles

| Principle | Rule |
|---|---|
| **Fixed cap, no folding** | Set max turns at 60% of model's context window. When exceeded, drop oldest turns silently. No compaction, no summarization, no folding service. |
| **Stable prefix = cache wins** | The prefix before the latest turn never changes. Prompt cache stays hot across requests. |
| **Dropped turns = tool opportunity** | When turns are dropped, inject one line: "Prior turns trimmed. Use `context(query:)` to retrieve details." |
| **RAG for everything outside context** | Every turn is indexed in the vector store. The model can retrieve anything it needs. |

### 1.3 RAG Principles

| Principle | Rule |
|---|---|
| **Two indexes, one purpose** | SQLite FTS5 for code (precision). FAISS for conversations (semantic). No overlap. |
| **Model has a tool** | `context` tool gives the model direct access to RAG. Not passive injection. |
| **Active, not passive** | No automatic RAG injection unless the model explicitly requests it. The model calls `context()` when it needs prior work. |
| **Recency-weighted** | Newer results score higher. Old code embeddings are not indexed — only conversations + tool results. |

---

## 2. Tool Set

### 2.1 The 12 Tools

```
read        — Read file contents with line range pagination
edit        — Edit existing file by line range (surgical, preferred for all edits)
write       — Create new file or overwrite existing
bash        — Execute shell commands
search      — Search codebase: symbols, text, filenames (SQLite FTS5)
ls          — List files and directories
glob        — Find files by pattern matching
rm          — Delete a file or empty directory
context     — Retrieve prior conversation context via RAG (FAISS)
plan        — Structured multi-step task planning
web_search  — Search the web
web_fetch   — Fetch and extract content from a URL
```

Plus 3 pinned rule helpers: `pinned_rule_add`, `pinned_rule_remove`, `pinned_rule_list`.

### 2.2 Tool Name Rationale

| Name | Industry match | Rationale |
|---|---|---|
| `read` | Claude Code `Read`, OpenCode `read` | Models trained on this name |
| `edit` | Claude Code `Edit`, OpenCode `edit` | Models trained on this name |
| `write` | OpenCode `write` | Standard verb |
| `bash` | Claude Code `Bash`, OpenCode `bash` | Highest model familiarity |
| `search` | — | Single entry for ALL code discovery |
| `ls` | Standard CLI | Every model knows `ls` |
| `glob` | Claude Code `Glob`, OpenCode `glob` | Standard pattern match name |
| `rm` | Standard CLI | Every model knows `rm` |
| `context` | — | Self-documenting: "give me context about X" |
| `plan` | Claude Code `EnterPlanMode` | Already in use, short |
| `web_search` | Claude Code `WebSearch`, OpenCode `websearch` | Industry standard |
| `web_fetch` | Claude Code `WebFetch`, OpenCode `webfetch` | Industry standard |

### 2.3 Deleted Tools and Their Replacements

| Deleted | Replaced by | Reason |
|---|---|---|
| `read_file` | `read` | Renamed for model familiarity |
| `patch_file` | `edit` | Renamed for model familiarity |
| `write_file` | `write` | Renamed for model familiarity |
| `replace_in_file` | `edit` | edit is superior (line-based, not string-match) |
| `run_command` | `bash` | Renamed for model familiarity |
| `search_project` / `grep` / `find_file` | `search` | Single unified search tool |
| `list_files` / `list_dir` | `ls` | Standard CLI name |
| `get_project_structure` | `ls` | Same operation |
| `locate_symbol` / `inspect_symbol` / `where_symbol` | `search` | search already does symbol lookup |
| `delete_file` | `rm` | Standard CLI name |
| `web_browse` | `web_fetch` | Renamed for clarity |
| `grep_search` / `search_files` / `find_in_files` | (alias deleted) | Unified into `search` |
| `create_file` / `write_files` / `write_to_file` | (alias deleted) | Unified into `write` |
| `edit_file` / `apply_patch` / `apply_diff` / `patch` | (alias deleted) | Unified into `edit` |
| `view_file` / `read` / `read_file_v2` | (alias deleted) | Unified into `read` |
| `find_by_name` / `find` | (alias deleted) | Unified into `glob` |
| `list_directory` / `list_dir` / `list_all_files` | (alias deleted) | Unified into `ls` |
| `index_find_files` / `index_list_files` / `index_read_file` | (alias deleted) | Aliases that add confusion |
| `index_search_text` / `index_search_symbols` / `index_list_symbols` | (deleted entirely) | Virtual tools with no implementation |
| `index_list_memories` / `index_add_memory` | (deleted entirely) | Virtual tools with no implementation |
| `internet_search` / `google` / `search_web` / `web` | (alias deleted) | Unified into `web_search` |
| `web_fetch` (old) / `fetch_url` / `http_get` / `browse` | (alias deleted) | Unified into `web_fetch` |
| `run_shell` / `bash` (old alias) / `terminal` / `execute_command` / `run_terminal_command` / `run_shell_command` / `cli-mcp-server_run_command` | (alias deleted) | Unified into `bash` |

---

## 3. Tool Prompt Templates

### 3.1 Universal Structure

Every tool prompt follows this exact structure:

```
## {name} — {one-line purpose}

**When to use:** {specific scenarios}

**Parameters:**
- {param} ({required|optional}, {type}): {description}

**Expected output:** {what the model receives}

**Common situations & recovery:**
- {issue}: {what to do}
```

No "When NOT to Use" sections. No negative language. No "Do NOT" — always "For X, use Y."

### 3.2 Tool Prompts

#### read

```
## read — Read file contents with optional line range

**When to use:** Before editing any file. Inspecting code, configs, or docs. Getting line numbers for edit calls.

**Parameters:**
- path (required, string): Path to the file.
- start (optional, integer): 1-based start line. Omit for line 1.
- end (optional, integer): 1-based end line (inclusive). Omit for EOF.

**Expected output:** File content with line numbers. Line count and size in status.
status: success | error
content.text: file content (line-numbered when using start/end)

**Common situations & recovery:**
- File not found: Use search or glob to locate it first.
- File is large: Use start/end to read only the range you need. The line numbers map directly to edit parameters.
```

#### edit

```
## edit — Edit an existing file by replacing a line range

**When to use:** ALL modifications to existing files. This is the primary mutation tool. For single-line changes, multi-line blocks, or entire function replacements.

**Parameters:**
- path (required, string): Path to the file.
- start (required, integer): 1-based line where replacement begins.
- end (required, integer): 1-based line where replacement ends (inclusive). Use same as start for single-line edits.
- content (required, string): The replacement text for the specified line range.

**Expected output:** Diff showing removed and added lines. Status confirmation.
status: success | error
content.text: diff output

**Common situations & recovery:**
- File not found: Create it with write instead.
- Line range invalid: Read the file again to get current line numbers.
- Read-before-write required: Call read on the file first, then retry edit.
```

#### write

```
## write — Create a new file or overwrite an existing one

**When to use:** Creating NEW files. For edits to existing files, use edit instead.

**Parameters:**
- path (required, string): Path for the new file.
- content (required, string): The full content to write.

**Expected output:** Status confirmation with byte count.
status: success | error
message: "Created path/to/file (123 bytes)"

**Common situations & recovery:**
- File already exists with important content: Use edit to make targeted changes instead.
```

#### bash

```
## bash — Execute a shell command

**When to use:** Running builds (npm run build, swift build). Running tests (npm test, swift test). Installing dependencies. Git operations. Any CLI operation needed.

**Parameters:**
- command (required, string): The shell command to execute.

**Expected output:** stdout, stderr, and exit code.
status: success | error
content.text: stdout
error.message: stderr content (on non-zero exit)

**Common situations & recovery:**
- Command not found: Install the dependency first.
- Non-zero exit code: Check the error output.
- Command timed out: Break the work into smaller commands.
```

#### search

```
## search — Search the codebase for code: symbols, text, filenames

**When to use:** FIRST tool for ANY code discovery. Finding where a function, class, or variable is defined or used. Locating files when you know what they contain but not their name.

**Parameters:**
- query (required, string): The code or text to search for.
- max_results (optional, integer): Max results (default 20, max 100).

**Expected output:** Matches grouped by file with line numbers, match type, and context snippet.
status: success
content.items: [{path, line, kind, context}, ...]
message: "Found N matches in M files"

**Common situations & recovery:**
- No results: Try a broader query, or part of the name. Use search rather than reading files manually.
```

#### ls

```
## ls — List files and directories

**When to use:** Exploring project structure. Finding files when you know part of the name.

**Parameters:**
- path (optional, string): Directory to list. Defaults to current directory.
- filter (optional, string): Case-insensitive name substring filter.

**Expected output:** Entries with name, full path, and type (file/directory).
status: success
content.items: [{name, path, type}, ...]

```

#### glob

```
## glob — Find files by pattern matching

**When to use:** Finding files by extension or name pattern. Quick lookup before reading or editing.

**Parameters:**
- pattern (required, string): Glob pattern (e.g., "src/**/*.swift", "**/*.test.ts").

**Expected output:** Matching file paths sorted by modification time.
status: success
content.items: [{path: "..."}, ...]
```

#### rm

```
## rm — Delete a file or empty directory

**When to use:** Removing files that are no longer needed. Cleaning up temp or generated files.

**Parameters:**
- path (required, string): Path to delete.

**Expected output:** Deletion confirmation.
status: success | error
message: "Deleted path/to/file"

**Common situations & recovery:**
- File not found: Already deleted or path is wrong.
- Directory not empty: Delete files inside it first.
```

#### context

```
## context — Retrieve prior conversation context from the knowledge store

**When to use:** After context has been trimmed (you'll see a notice). When you need to recall prior findings, decisions, or code patterns from earlier in this session or previous sessions. When the user references work done in a prior conversation.

**Parameters:**
- query (required, string): What you need to recall. Be specific about the topic, file, or decision.
- max_results (optional, integer): Max results to return (1-10, default 5).

**Expected output:** Ranked snippets from prior work with source references and timestamps.
status: success
content.items: [{text, source, timestamp, relevance}, ...]
message: "Found N relevant results"

**Recovery:**
- No results: Try a different query — use more specific terms or keywords from the prior work.
- Results not helpful: Refine the query to focus on the exact aspect you need.
```

#### plan

```
## plan — Structured multi-step task planning

**When to use:** Any task with multiple steps, files, or phases. When you need to track progress across a complex workflow.

**Actions:**
- "init": Start planning. Enter research phase — use all tools to explore.
- "finishTask": End current phase. Research: provide task breakdown. Execution: mark the CURRENT task done and advance.
- "raiseQuestion": Pause and ask the user for clarification.
- "breakOutCantContinue": Abort the plan with a reason.

**Expected output:** Plan progress confirmation.
status: success | error
message: "Plan updated — N tasks, M remaining"
```

#### web_search

```
## web_search — Search the web

**When to use:** Finding documentation, tutorials, error solutions. Researching libraries, frameworks, or APIs.

**Parameters:**
- query (required, string): The search query.

**Expected output:** Search results with title, URL, and snippet.
status: success
content.items: [{title, url, snippet}, ...]
```

#### web_fetch

```
## web_fetch — Fetch a URL and extract its readable content

**When to use:** Reading full articles, documentation pages, or API references after discovering them with web_search.

**Parameters:**
- url (required, string): The full URL to fetch.

**Expected output:** Page title and main body text.
status: success | error
content.text: page title and readable content

**Common situations & recovery:**
- URL unreachable: Check the URL or try web_search to find an alternative source.
```

### 3.3 Universal Feedback Contract

Every tool returns feedback in this structure:

```
status: success | error | partial
message: Human-readable summary (1-2 lines)
content: Present for query tools (read, search, ls, glob, context, web_search, web_fetch). Null for mutation tools.
error:
  code: MACHINE_READABLE_CODE    # FILE_NOT_FOUND, LINE_RANGE_INVALID, READ_BEFORE_WRITE, etc.
  recoverable: true               # True = retry with different approach
  alternatives:                   # Suggested recovery paths
    - description: "What to do"
      toolName: "tool_name"
```

---

## 4. Context Management

### 4.1 Strategy: Fixed Cap, No Folding

```
MAX_TURNS = ceil(model_window * 0.6 / avg_turn_cost)
```

For a 32K context model:
- 60% = ~19,200 tokens for input
- Average turn cost (system + 1 user + 1 assistant + tool results) ≈ 4,000 tokens
- MAX_TURNS ≈ 4-5 turns

**Behavior:**
1. Count turns (user message + assistant response = 1 turn)
2. When MAX_TURNS exceeded, drop the oldest turn silently
3. Inject after the system prompt: "Prior turns trimmed. Use context(query:) to retrieve details."
4. The newest turn is always present. The context before it is stable (cache-friendly).

### 4.2 Why This Works

| Concern | How it's addressed |
|---|---|
| **Cache performance** | Prefix before the newest turn never changes. Cache stays hot across all requests. |
| **Lost in the middle** | No middle. Only the latest N turns. Everything else was dropped. |
| **Model awareness** | The trim notice tells the model what happened and how to recover. |
| **No complexity** | No folding service. No summarization. No subject-change detection. One constant, one if-check, one array slice. |
| **RAG fills gaps** | Context tool gives the model instant access to anything dropped. |

### 4.3 What Gets Deleted

| File | Reason |
|---|---|
| `Services/CloudPipeline/ConversationFoldingHandler.swift` | Entire folding subsystem deleted |
| `Services/ConversationFoldingService.swift` | Entire folding subsystem deleted |
| `Services/ConversationFoldingThresholds.swift` | Entire folding subsystem deleted |
| `Services/ConversationFoldStore.swift` | Entire folding subsystem deleted |
| `Services/ConversationFoldResult.swift` | Entire folding subsystem deleted |
| `Services/ConversationFoldIndexEntry.swift` | Entire folding subsystem deleted |
| `plans/rag-enrichment-mess-prevention-spec.md` | Replaced by this spec |

### 4.4 Implementation

```swift
// In ConversationSendCoordinator.send(), before sending:
let maxTurns = 5  // typical for 32K context
if historyCoordinator.messages.count > maxTurns * 2 {
    // Drop oldest turns, keep the newest N
    let excess = historyCoordinator.messages.count - maxTurns * 2
    historyCoordinator.trimFirst(excess)
    // Inject context reminder
    historyCoordinator.inject(afterSystemPrompt: 
        "Prior turns trimmed. Use context(query:) to retrieve details.")
}
```

---

## 5. RAG Architecture

### 5.1 Two Indexes, No Overlap

```
                        RAG SYSTEM
                            │
            ┌───────────────┴───────────────┐
            ▼                               ▼
     SQLite FTS5                      FAISS Vector Store
  (Codebase Index)                 (Knowledge Index)
            │                               │
            │ Indexes:                      │ Indexes:
            │   Symbol names                │   Conversation turns
            │   Symbol locations            │   Tool results
            │   File paths                  │   User decisions
            │   Full-text code              │   Preferences
            │                               │
            │ Query:                        │ Query:
            │   search(query, ...)          │   context(query, ...)
            │   (precision: find exact)     │   (semantic: find related)
            │                               │
            │ Updates:                      │ Updates:
            │   Live reindex on file change │   Append-only on each turn
            │   (reindexProject())          │   No staleness cleanup needed
```

### 5.2 What the Vector Store Indexes

| Data source | When | Retention |
|---|---|---|
| User message + assistant response | Every turn | Permanent (recency-weighted during retrieval) |
| Tool results (key outputs) | After each tool execution | Permanent |
| User preferences / decisions | When explicitly stated | Permanent |

### 5.3 What It Does NOT Index

| Data source | Why not | How it's handled |
|---|---|---|
| Raw file contents | Code changes, becomes stale | SQLite FTS5 handles code retrieval |
| Entire conversation verbatim | Redundant | Each turn = one entry |
| Binary data | No semantic value | Skipped |

### 5.4 Merging `retrieveMemoryCandidates` Stub

The `retrieveMemoryCandidates()` method in `CodebaseIndexRAGRetriever` currently returns `[]`. It should be wired to the vector store: `VectorStoreService.searchByText()` which already searches conversation history embeddings. This turns the dead stub into a live connection.

### 5.5 context Tool Wiring

```swift
// Services/Tools/ContextTool.swift
struct ContextTool: AITool {
    let name = "context"
    let description = "Retrieve prior conversation context from the knowledge store. Use after turns have been trimmed, or when you need to recall prior findings, decisions, or code patterns."
    
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What you need to recall. Be specific about the topic, file, or decision."
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Max results to return (1-10, default 5)."
                ]
            ],
            "required": ["query"]
        ]
    }
    
    let vectorStoreService: VectorStoreService?
    
    func execute(arguments: ToolArguments) async throws -> String {
        guard let query = arguments.raw["query"] as? String else {
            return "Missing query."
        }
        let maxResults = min(10, max(1, arguments.raw["max_results"] as? Int ?? 5))
        
        guard let vectorStoreService, vectorStoreService.isAvailable else {
            return "Knowledge store not available."
        }
        
        let results = await vectorStoreService.searchByText(query, limit: maxResults)
        // Format results as ToolFeedback envelope
        // ...
    }
}
```

### 5.6 RAG as Active Tool, Not Passive Injection

- `ragEnabledDuringToolLoop` setting is **removed** — no automatic RAG injection
- The `context` tool replaces automatic injection
- The model decides when to retrieve
- The only automatic addition is the one-line notice after context trimming

---

## 6. Query → Code Block → Alteration Pipeline

```
User Query
    │
    ▼
1. UNDERSTAND the request
   search(code)  → find relevant code
   ls / glob     → locate files
   context()     → recall prior work
   web_search    → research approach
    │
    ▼
2. PLAN the work (for multi-step tasks)
   plan(init) → research → plan(finishTask, summary: "tasks...")
    │
    ▼
3. READ what needs to change
   read(file)           → current content
   read(file, start:42, end:60) → specific lines
    │
    ▼
4. IMPLEMENT the changes
   edit(path, start..end, content) → existing files
   write(path, content)             → new files
   rm(path)                         → delete files
   bash(command)                    → run migrations, install deps
    │
    ▼
5. VERIFY
   bash("npm test")         → run tests
   bash("npm run build")    → verify build
   read(file, start..end)   → verify changes
    │
    ▼
6. ITERATE (if more tasks) or DELIVER
   plan(finishTask, summary: "changed X, verified Y")
```

### 6.1 Engine-Level Guidance

| Situation | Tool Behavior |
|---|---|
| Model calls `write` on an existing file | Returns: "File exists. Use `edit` to make targeted changes." |
| Model calls `edit` without prior `read` | Returns: "Reading file first... [reads] Edit applied." (auto-reads) |
| Model reads same file twice in a row | Returns cached result from current turn (no re-read) |
| Context trimmed | Injects notice: "Prior turns trimmed. Use context(query:) to retrieve details." |

---

## 7. System Prompt Assembly

### 7.1 Assembly Order

```
1. PINNED RULES (from pinned_rule_* tools)
2. BASE SYSTEM PROMPT       → PromptFiles/System/base-system-prompt.md
3. TOOL USAGE GUIDE          → PromptFiles/System/tool-system-prompt-full.md
4. TOOL REFERENCE            → PromptFiles/Tools/v3/*.md (all 12 tools)
5. FEEDBACK CONTRACT         → PromptFiles/Tools/v3/feedback-format.md
6. CONTEXT NOTICE            → Injected if turns were trimmed
7. MODE PROMPT               → PromptFiles/System/mode-coder.md
8. PROJECT CONTEXT           → Project root path, OS info
```

### 7.2 Mode Prompt (Coder)

```markdown
# Coder Mode

You have full tool access to build, debug, and ship code.

## Your Workflow

1. **Search first.** Use `search` to find relevant code before reading files. Use `context` to recall prior work from trimmed turns.
2. **Read exactly what you need.** Use `read` with line ranges.
3. **Edit surgically.** Use `edit` for all existing file changes. Use `write` only for new files.
4. **Verify.** Use `bash` to build and test.
5. **Track progress.** Use `plan` for multi-step tasks.
```

### 7.3 Tool Reference Section

Each tool prompt template (Section 3.2) is loaded in order under a `## Tool Reference` heading.

The tool reference includes these tools in this order:
1. `read`
2. `edit`
3. `write`
4. `search`
5. `ls`
6. `glob`
7. `rm`
8. `context`
9. `bash`
10. `plan`
11. `web_search`
12. `web_fetch`
13. `feedback-format`

---

## 8. Classification Sets (ToolTaxonomy)

Replace the 5+ scattered classification sets with a single source:

```swift
enum ToolTaxonomy {
    static let readOnly: Set<String> = [
        "read", "search", "ls", "glob", "context", "web_search", "web_fetch"
    ]
    static let mutation: Set<String> = [
        "edit", "write", "rm"
    ]
    static let execution: Set<String> = [
        "bash"
    ]
    static let planning: Set<String> = [
        "plan"
    ]
    static let pins: Set<String> = [
        "pinned_rule_add", "pinned_rule_remove", "pinned_rule_list"
    ]
    static let all: Set<String> = readOnly.union(mutation).union(execution).union(planning).union(pins)
}
```

All references to old classification sets (`readOnlyLoopToolNames`, `mutationRecoveryToolNames`, `MutationTools.readOnlyNames`, etc.) are replaced with `ToolTaxonomy.*`.

---

## 9. Migration Plan

### Phase 1: Context Overhaul

1. Delete `ConversationFoldingHandler.swift`, `ConversationFoldingService.swift`, `ConversationFoldingThresholds.swift`, `ConversationFoldStore.swift`, `ConversationFoldResult.swift`, `ConversationFoldIndexEntry.swift`
2. Add context trimming logic to `ConversationSendCoordinator.send()` (fixed-cap, drop oldest)
3. Inject trim notice when turns are dropped
4. Build + test

### Phase 2: Tool Renames + Cleanup

1. Rename all 12 tool structs and `name` properties
2. Delete `ToolAliasRegistry.swift`
3. Delete all deleted tool files (Section 2.3)
4. Update `ConversationToolProvider.allTools()`
5. Create `ToolTaxonomy.swift`, update all references
6. Build + test

### Phase 3: context Tool + RAG Wiring

1. Create `Services/Tools/ContextTool.swift`
2. Wire `retrieveMemoryCandidates()` in `CodebaseIndexRAGRetriever` to `VectorStoreService.searchByText()`
3. Remove `ragEnabledDuringToolLoop` setting (no more passive injection)
4. Add `ContextTool` to `ConversationToolProvider.allTools()`
5. Build + test

### Phase 4: Prompts

1. Write all 12 tool prompts + feedback-format.md to `PromptFiles/Tools/v3/`
2. Update `SystemPromptAssembler.swift` to load v3 prompts
3. Update `PromptFiles/System/mode-coder.md`
4. Delete v2 prompts
5. Build + test

### Phase 5: Legacy Cleanup

1. Delete `EnhancedAITool` protocol (`Services/AITool+Enhanced.swift`)
2. Delete `LocalFindTool`, `LocateSymbolTool`, `InspectSymbolTool`, `WhereSymbolTool`
3. Delete `GrepTool`, `ReplaceInFileTool`, `GetProjectStructureTool`
4. Delete `Prompts/Tools/v2/` (all 16 files)
5. Build + test

---

## 10. Files to Create / Modify / Delete

### NEW FILES

| File | Purpose | Phase |
|---|---|---|
| `Services/Tools/ContextTool.swift` | context tool (RAG retrieval) | P3 |
| `Services/ToolTaxonomy.swift` | Single classification source | P2 |
| `PromptFiles/Tools/v3/read.md` | read tool prompt | P4 |
| `PromptFiles/Tools/v3/edit.md` | edit tool prompt | P4 |
| `PromptFiles/Tools/v3/write.md` | write tool prompt | P4 |
| `PromptFiles/Tools/v3/search.md` | search tool prompt | P4 |
| `PromptFiles/Tools/v3/ls.md` | ls tool prompt | P4 |
| `PromptFiles/Tools/v3/glob.md` | glob tool prompt | P4 |
| `PromptFiles/Tools/v3/rm.md` | rm tool prompt | P4 |
| `PromptFiles/Tools/v3/context.md` | context tool prompt | P4 |
| `PromptFiles/Tools/v3/bash.md` | bash tool prompt | P4 |
| `PromptFiles/Tools/v3/plan.md` | plan tool prompt | P4 |
| `PromptFiles/Tools/v3/web_search.md` | web_search tool prompt | P4 |
| `PromptFiles/Tools/v3/web_fetch.md` | web_fetch tool prompt | P4 |
| `PromptFiles/Tools/v3/feedback-format.md` | universal contract | P4 |

### MODIFIED FILES

| File | Change | Phase |
|---|---|---|
| `Services/Tools/ReadFileTool.swift` | rename `name` to `read` | P2 |
| `Services/Tools/WriteFileTool.swift` | rename to `WriteTool`, `name` to `write`, remove "prefer patch_file" | P2 |
| `Services/Tools/PatchFileToolAdapter.swift` | rename to `EditTool`, `name` to `edit` | P2 |
| `Services/Tools/DeleteFileTool.swift` | rename to `RmTool`, `name` to `rm` | P2 |
| `Services/Tools/RunCommandTool.swift` | rename to `BashTool`, `name` to `bash` | P2 |
| `Services/Tools/SearchProjectTool.swift` | rename to `SearchTool`, `name` to `search` | P2 |
| `Services/Tools/FindFileTool.swift` | rename to `GlobTool`, `name` to `glob`, update parameters | P2 |
| `Services/Tools/ListFilesTool.swift` | rename to `LsTool`, `name` to `ls` | P2 |
| `Services/Tools/WebBrowseTool.swift` | rename to `WebFetchTool`, `name` to `web_fetch` | P2 |
| `Services/ConversationToolProvider.swift` | update tool list, add ContextTool | P2+P3 |
| `Services/ConversationSendCoordinator.swift` | add context trimming logic | P1 |
| `Services/CloudPipeline/StallDetector.swift` | use ToolTaxonomy | P2 |
| `Services/CloudPipeline/ToolLoopHandler.swift` | use ToolTaxonomy | P2 |
| `Services/CloudPipeline/FinalResponseHandler.swift` | use ToolTaxonomy | P2 |
| `Services/CloudPipeline/QAReviewHandler.swift` | use ToolTaxonomy | P2 |
| `Services/LocalModels/LocalModelToolProvider.swift` | update safe tool names | P2 |
| `Services/Tools/ToolAdapterFactory.swift` | update capabilities map | P2 |
| `Services/ConversationPolicy.swift` | update tool names in filters | P2 |
| `Services/RAG/CodebaseIndexRAGRetriever.swift` | wire `retrieveMemoryCandidates` to vector store | P3 |
| `Services/SystemPromptAssembler.swift` | load v3 prompts | P4 |
| `PromptFiles/System/mode-coder.md` | update tool references | P4 |

### DELETED FILES

| File | Reason | Phase |
|---|---|---|
| `Services/CloudPipeline/ConversationFoldingHandler.swift` | Context strategy changed | P1 |
| `Services/ConversationFoldingService.swift` | Context strategy changed | P1 |
| `Services/ConversationFoldingThresholds.swift` | Context strategy changed | P1 |
| `Services/ConversationFoldStore.swift` | Context strategy changed | P1 |
| `Services/ConversationFoldResult.swift` | Context strategy changed | P1 |
| `Services/ConversationFoldIndexEntry.swift` | Context strategy changed | P1 |
| `Services/Tools/GrepTool.swift` | Folded into search | P2 |
| `Services/Tools/ReplaceInFileTool.swift` | Replaced by edit | P2 |
| `Services/Tools/LocalFindTool.swift` | Folded into search | P2 |
| `Services/Tools/LocateSymbolTool.swift` | Folded into search | P2 |
| `Services/Tools/InspectSymbolTool.swift` | Folded into search | P2 |
| `Services/Tools/WhereSymbolTool.swift` | Folded into search | P2 |
| `Services/Tools/GetProjectStructureTool.swift` | Folded into ls | P2 |
| `Services/ToolAliasRegistry.swift` | No longer needed | P2 |
| `Services/AITool+Enhanced.swift` | Dead protocol | P5 |
| `PromptFiles/Tools/v2/` (16 files) | Replaced by v3 | P4 |
