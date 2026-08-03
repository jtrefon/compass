# Assessment: compass Agentic Pipeline — July 2026

## What Works

| Area | Status | Evidence |
|---|---|---|
| **Tool selection** | ✅ No bash in `.coder` | Agent uses `ls`, `read` — no bash+grep flood |
| **Indexing** | ✅ Working | 2,315 resources, 28,792 symbols (WordPress) |
| **Tool results** | ✅ Window-aware caps | modelID now passes through `truncateForModel` |
| **Double-commit bug** | ✅ Fixed | Removed duplicate `commitToolResult` in post-loop |
| **Path normalization** | ✅ Fixed | `Users` removed from hallucinatedRoots |
| **`isSending` stuck** | ✅ Fixed | `defer` block always sets `isSending = false` |
| **Harness KPI** | ✅ Added | Duplicate detection, flood risk, success/failure report |
| **Read tool directory check** | ✅ Added | Clear error: "Use `ls` to list its contents" |
| **Sandbox error messages** | ✅ Improved | `recoverySuggestion` with actionable guidance |
| **Plan tool promoted** | ✅ Pain-point hook | "Without a plan, you risk forgetting steps" |
| **Pre/post cleanup** | ✅ Fixed | No `git clean -fd` — untracked files preserved |
| **Recovery context spam** | ✅ Fixed | Draft messages excluded from recovery injection |

## What Still Has Issues

| Issue | Detail | Priority |
|---|---|---|
| **16+ tool calls for simple tasks** | Agent reads excessively before writing — inflates 3-5x | **HIGH** |
| **No `search` tool usage** | Agent used `read` 14×, `search` 2× — not using the index | **HIGH** |
| **No FTS5 table** | `sqlite_master` shows no FTS virtual table — full-text search is broken | **HIGH** |
| **Provider timeout** | Kilo Code stream idle deadline kills long-thinking sessions | **MEDIUM** |
| **Agent never writes in harness** | Provider timeout kills test before write phase | **MEDIUM** |
| **Tool misuse on directories** | Agent still tries `read .` despite prompt fixes | **LOW** |

## The Number One Issue

**No FTS5 table.** The index has 28,792 symbols but no full-text search capability. When the agent calls `search` with a query like "wordpress plugin registration user", the symbol search finds nothing (no matching symbol name), the full-text search finds nothing (no FTS table), the filename search finds nothing (wrong query format), and the agent falls back to `read`-everything approach.

This explains:
- Why `search` returned 0 results in our earlier test (`resultLen=58` with 0 matches)
- Why the agent does 14 reads instead of 1 search
- Why the agent relies on `read` for discovery

The FTS5 table should be created by the indexer during `setupDatabase()` in `DatabaseManager.swift`. Let me check if the FTS5 setup is being skipped.

## Next Priority

**Fix FTS5 table creation** — without full-text search, the `search` tool is useless. The agent has no choice but to read files individually. Once FTS5 works, `search` will return relevant file matches, and the agent will use it instead of reading everything.
