# Agent Tooling Audit — Efficiency & Reliability Report

> **Origin:** Real session observed on 2026-07-22 in `~/Projects/WordPress` (plugin: `career-register`).
> **User prompt:** *"could you review career-register plugin for me? check if its finished and ready for production release?"*
> **Expected cost:** 1 `ls` + 1 `search`/`glob` + ~5 `read` = **~7 tool calls, ~10 s, ~5 k tokens**.
> **Actual cost (session `BA0AF9…`):** 49 `bash` + 14 `ls` + 6 `read` + 6 `glob` + 4 `search` = **79 tool calls, ~5 min, ~180 k tokens — no delivered review.**

This document is the post-mortem of that session plus a holistic audit of the agent toolchain. Each section lists the **Problem**, **Evidence**, **Fix**, and the **Owning code path**.

---

## Summary of root causes

| # | Problem | Impact |
|---|---|---|
| 1 | `edit` is line-range based, not `old_string`/`new_string` | Forces a `read` roundtrip on every edit; brittle to off-by-one line counts |
| 2 | `search` claims "semantic" but embeddings were removed | Model trusts a capability the tool doesn't have; produces wrong dispatch |
| 3 | Mode prompt lists **legacy tool names** that don't match the live schema | Model emits `read_file`, `run_command`, `search_project` — silently aliased, but with constant uncertainty |
| 4 | v3 tool docs **lie about parameter names** | `read.md` says `start`/`end`; the schema is `start_line`/`end_line`/`char_offset`/`char_limit`. `glob.md` omits the required `path` arg |
| 5 | `glob` requires `path` | Forces a redundant `ls` before any glob; industry standard glob is pattern-only from project root |
| 6 | `bash` tool runs in project root, but `project-root-context.md` doesn't say so | Model prepends the project folder name (e.g. `ls WordPress/wp-content/…`) and burns iterations on `cd`/cwd errors |
| 7 | `index_exclude` excludes `vendor`/`build`/`bin` but **not WordPress core** (`wp-admin`, `wp-includes`) | FTS poisons all queries with thousands of WP core matches; the plugin's own files are buried |
| 8 | Tool-loop recovery causes **amnesia restarts** | The session shows 15+ repetitions of *"Let me start by exploring the career-register plugin…"* — the recovery rebuilds the focused execution messages and the model forgets prior `ls`/`read` results |
| 9 | `ls`/`read` results are not cached by signature across recovery cycles | The in-loop `readResultCache` is per-loop only; once recovery fires the model re-issues identical `ls` calls |
| 10 | Initial system prompt has no project-structure overview | Agent has no idea what's "project code" vs "vendor" until it spends 5+ `ls` calls discovering it |
| 11 | `requestLikelyRequiresMutation` uses naive substring matching | "Could you **update** the comment" is treated the same as "create a new file"; misleading for review-style prompts |

---

## 1. The `edit` tool is line-range, not search-and-replace

**Problem.** `PatchFileToolAdapter` (`compass/Services/Tools/PatchFileToolAdapter.swift:6`) takes `start_line`, `end_line`, and `new_content`. To use it the model MUST first call `read` to discover line numbers — adding a mandatory roundtrip before every edit. It is also brittle: a single off-by-one line count corrupts the file (the tool replaces whatever lives at those lines, even if the model's mental model is stale). Industry standard tools (Aider, Cline, Cursor, opencode itself) use `old_string`/`new_string` — the tool locates the unique match itself and refuses ambiguous matches.

**Evidence.** Session `BA0AF9…`: 6 `read` and 6 `glob` calls precede any review. `FileToolWriteApplier.swift:66` literally tells the model: *"Read the file first with read_file, then use patch_file with line numbers from the read output."* — encoding the extra roundtrip as policy.

**Fix.**
- Add a new `edit` overload that accepts `old_string` + `new_string` (and optional `replace_all`). Keep the line-range variant as `edit_lines` for edge cases (e.g. whitespace-sensitive blocks the model can't quote reliably).
- Use a robust diff/locate routine: strip leading indentation when matching, require uniqueness, surface "found N matches — supply more context" errors instead of patching the wrong occurrence.
- Update `FileToolWriteApplier`'s guard message to point at the new tool, not `patch_file`.

**Owning path:** `compass/Services/Tools/PatchFileToolAdapter.swift`, `compass/Services/Tools/FileToolWriteApplier.swift`, `Prompts/Tools/v3/edit.md`.

---

## 2. `search` is mis-advertised as semantic

**Problem.** `SearchProjectTool.swift:8-13` describes itself as "semantic search (vector similarity)". But the implementation says (line 55): *"Semantic search via MLX embeddings removed — RAG handles contextual retrieval."* The actual dispatch is **symbol lookup → FTS → filesystem grep → filename match**. None of these are semantic. The model is told to expect concept-level results and gets keyword hits instead.

**Evidence.** In the WordPress session the model issued `search "career-register"` once and then immediately fell back to `bash`-based `find`/`grep`. The symbol/FTS index was polluted (see §7), the search returned mostly WP-core noise, and the model's confidence in the tool collapsed.

**Fix.**
- Either restore a real embedding-backed semantic search *or* change the description and the docs to honestly say "symbol + full-text + filename + grep fallback". Do not ship both an empty embedding block and a "semantic" claim.
- Surface the **dispatch method actually used** in the result (e.g. `via: symbol`, `via: fts`, `via: grep`, `via: filename`). This lets the model reason about recall instead of trusting a black box.
- Always include the canonical `file:line:context` triple in every entry, **never** silently truncate to 20 matches per file (formatResults at line 224) — degrade with pagination, not with hiding matches.

**Owning path:** `compass/Services/Tools/SearchProjectTool.swift`, `Prompts/Tools/v3/search.md`.

---

## 3. Mode prompt lists legacy tool names

**Problem.** `Prompts/System/mode-coder.md:9` advertises:

```
read_file, write_file, patch_file, delete_file, list_files, find_file, grep,
search_project, run_command, web_search, web_browse, get_project_structure
```

The *actual* canonical tool names registered in `ConversationToolProvider.swift` are:

```
read, write, edit, delete, ls, glob, search, bash, web_search, web_fetch,
context, plan
```

`ToolAliasRegistry.swift:31-45` silently aliases the legacy names to the canonical ones, so the model does not immediately crash — but it costs the model confidence on every call ("will `run_command` work? will `read_file`?"). Worse, the mode prompt references tools that don't exist at all (`get_project_structure`, `web_browse`).

**Evidence.** The WordPress session shows the model oscillating between `search` and `glob` and `bash`+`grep`, never using `search_project` even when the mode prompt told it that's the name. Each switch costs a roundtrip.

**Fix.**
- Rewrite `mode-coder.md`, `mode-chat.md`, `mode-agent.md` to use the canonical names *and nothing else*.
- Delete the alias registry once all prompts/harnesses/tests are migrated, OR keep it as an invisible last-line-of-defense but remove all *prompt-level* mentions of legacy names.
- Audit `compassTests` and `compassHarnessTests` (search for `read_file`, `write_file`, `create_file`, `patch_file`, `run_command`, `search_project`, `list_files`, `find_file`) — these tests document the legacy names and should be rewritten in lockstep.

**Owning path:** `Prompts/System/mode-*.md`, `compass/Services/ToolAliasRegistry.swift`.

---

## 4. v3 tool docs lie about parameter names

**Problem.** The `Prompts/Tools/v3/*.md` files contradict the tool schemas the model is being called with.

| Tool | `v3/*.md` says | Actual schema in `*Tool.swift` |
|---|---|---|
| `read` | `path`, `start`, `end` | `path`, `start_line`, `end_line`, `char_offset`, `char_limit` |
| `glob` | `pattern`, `max_results`, `offset` (no `path` mentioned) | `pattern`, `path` **(required)**, `max_results`, `offset` |
| `ls` | `path`, `filter`, `limit`, `offset` | same |
| `search` | `query`, `max_results`, `offset` | same |
| `edit` | `path`, `start_line`, `end_line`, `new_content` | matches |
| `bash` | `command` | `action`, `command`, `working_directory`, `session_id`, `input`, `signal`, `wait_seconds` |

The model sees the *v3 docs* in the system prompt (assembled in `SystemPromptAssembler.swift:50-69`). The schema it sees in the *function-calling* layer is the one in `*Tool.swift`. When they disagree the model under-uses parameters (e.g. never paginates `read` because it doesn't know `start_line` exists) and gets validation errors.

**Evidence.** `Prompts/Tools/v3/read.md:7-8` says `start` and `end`. `ReadFileTool.swift:22-35` defines `start_line`/`end_line`. Any model that follows the doc instructions *exactly* will be silently ignored when it passes `"start": 50`.

**Fix.** Single-source the parameter list. Either:
- Generate `v3/*.md` from the tool schemas at build time (preferred), or
- Move the parameter list out of the markdown entirely and let the JSON schema be authoritative; keep `v3/*.md` only for *when to use* + *output format*.

Until one of these is done, audit each `v3/*.md` against its tool's `parameters` dictionary and reconcile.

**Owning path:** `Prompts/Tools/v3/*.md`, `compass/Services/SystemPromptAssembler.swift`.

---

## 5. `glob` requires `path`

**Problem.** `FindFileTool.swift:29` declares `"required": ["pattern", "path"]`. The v3 doc (`glob.md`) doesn't mention `path` at all — and even if it did, requiring `path` is wrong for a project-scoped glob. The standard contract (and what the user reported the agent should already do) is: `glob("**/career-register/**/*.php")` → returns matches under the project root, no `ls` preamble.

**Evidence.** WordPress session `BA0AF9…`: 14 separate `ls` calls, 6 of which are clearly the model trying to enumerate directories before issuing a `glob`. Two unnecessary roundtrips for every file-discovery task.

**Fix.**
- Drop `path` from required; default the search root to the project root.
- Allow optional `path` to scope to a subdirectory (e.g. `wp-content/plugins/`).
- Match `v3/glob.md` to the new schema, and reference `glob` from `mode-coder.md` as the primary file-discovery tool.

**Owning path:** `compass/Services/Tools/FindFileTool.swift`, `Prompts/Tools/v3/glob.md`.

---

## 6. `bash` cwd is project root — but the prompt doesn't say so

**Problem.** `TerminalTools.swift:485` defaults `workingDirectory` to `projectRoot`. `RunCommandSessionStore.start` then sets `process.currentDirectoryURL = workingDirectory` (line 184). So `bash` *always* runs in project root.

But `Prompts/System/project-root-context.md` only says "use relative paths like `package.json`", without saying the **bash shell is already there**. The model sees paths like `wp-content/plugins/career-register/` in the tool output and *prepends* the project's folder name, because it assumes `bash` starts in the parent of the project. That assumption produces errors like:

```
error: The file "WordPress" doesn't exist.
```

over and over in `BA0AF9…`. The model tried `ls WordPress/wp-content/…`, `cd WordPress && …`, etc. Each error cost a full roundtrip.

The corrective exists *only* in `bash.md:12-14`, a tool the model doesn't read closely until it has already wasted turns.

**Fix.**
- In `project-root-context.md`, add an explicit section:

  ```
  ## Shell working directory
  Every `bash` call runs with cwd = the project root above. NEVER prepend
  the project folder name. Run `ls wp-content/plugins/`, not `ls WordPress/wp-content/plugins/`.
  ```
- Mirror the rule in the `bash` tool's **description** (the one-line field every provider shows in the function schema), not just in the markdown body.
- Have the bash tool *detect* the failure pattern: if the first command path equals `{projectRoot.lastPathComponent}/…`, return an error that says "cwd is `{actual projectRoot}` — drop the leading `WordPress/`".

**Owning path:** `Prompts/System/project-root-context.md`, `compass/Services/Tools/TerminalTools.swift:413`.

---

## 7. `index_exclude` doesn't exclude WordPress core

**Problem.** The default `index_exclude` ships with `vendor`, `node_modules`, `Pods`, etc. — but nothing about WordPress or any other framework. The WordPress project at `~/Projects/WordPress` has its code in `wp-content/plugins/<name>/` alongside ~10 000 files of WP core under `wp-admin/` and `wp-includes/`.

The indexer dutifully ingests the WP core. When the model calls `search "career-register"`, the FTS returns a wall of `wp-includes/user.php`, `wp-admin/users.php`, `wp-login.php` matches for `register` before (or instead of) the actual plugin's files. The model's signal-to-noise ratio collapses, and it falls back to `bash find`.

**Evidence.** `index_exclude` contents at `/Users/jack/Projects/WordPress/.ide/index_exclude` — none of the patterns match WordPress core.

**Fix.**
- Add a **per-project auto-detect** step to indexer bootstrap: if `wp-includes/` or `wp-config-sample.php` exists at project root, auto-append `wp-admin`, `wp-includes`, and `wp-content/plugins/*` *except* the user's own active plugin (a heuristic: the one most recently touched). Same idea for `next/`, `public/`, `vendor/`, `app/`, `dist/`.
- Ship a **starter-pack of `index_exclude` snippets** under `compass/Resources/IndexPacks/` keyed by detected framework (WordPress, React, Vite, SvelteKit, Rails, …). Initialize from them on first project open.
- Surface `index_exclude` in the UI so users can tune it without editing a dotfile.

**Owning path:** `compass/Services/Indexing/IndexerBootstrap*` (create if absent), default `index_exclude` template (look for it under `compass/Services/Indexing/` or `compass/Resources/`).

---

## 8. Tool-loop recovery causes "amnesia restarts"

**Problem.** Session `BA0AF9…` shows the assistant message **"Let me start by exploring the career-register plugin…"** appearing **15 separate times** with different phrasings:

```
"I'll review the career-register plugin thoroughly. Let me start by exploring its structure and code."
"I'll review the career-register plugin for you. Let me start by exploring its structure and code."
"Let me explore the full plugin structure and read all the files."
"I'll review the career-register plugin for production readiness. Let me start by exploring its structure and code."
"I'll find and review the career-register plugin. Let me start by locating it."
"I'll review the career-register plugin for production readiness. Let me start by finding and exploring the plugin."
"I'll start by exploring the career-register plugin structure and then do a thorough production-readiness review."
…
```

Each is followed by `bash bash`, `glob glob`, `search ls`, etc. — a restarting pattern with no memory of the previous restart. This is a tool-loop recovery path re-issuing the focused execution messages (`ToolLoopUtilities.buildFocusedExecutionMessages`, called from `ToolLoopHandler.swift:113` and `:148`, `:205`), which trims prior `tool_result` blocks and resets the model's narrative.

**Evidence.** `ToolLoopHandler.swift` has at least **six** recovery entry points that call `requestDiversifiedExecutionForRepeatedSignatures` / `requestFinalResponseForStalledToolLoop` / `buildFocusedExecutionMessages`:

- `:113` — pre-loop force-execution followup
- `:148` — empty visible-content recovery
- `:205` — `shouldRecover` for textual tool markup / force-execution
- `:343` — `repeatedCompletedSignatureStallThreshold`
- `:430` — `isFullyRepeatedSignatureBatch`
- `:491` — `repeatedWriteTargetStallThreshold`
- `:540` — read-only loop stall

Each of these can fire on a benign review task where the model is honestly "still researching" — and each rebuilds the message list from `historyCoordinator.requestMessages`, which may have been truncated by `MessageTruncationPolicy.truncateForModel`.

The model then thinks "hi, I'm a fresh agent" and re-introduces itself.

**Fix.**
- **Preserve a condensed "prior work" summary** in every recovery payload: "You have already called these N tools and read these M files. Don't re-explore. Continue from this state." (The `ToolFileAccessLedger.shared.readPaths` data already exists — surface it inline.)
- **Rate-limit recovery**: at most *one* recovery message per `toolIteration`, and at most *three* total. The current code can fire multiple recoveries in adjacent iterations and the model never gets to "do the actual work".
- **Distinguish read-only review from mutation-stall**: the recovery paths are all named after mutation problems (`repeatedWriteTarget`, `nonRecoverableMutationFailure`, …) but trigger on any non-progress. For a `chat`-style review task the right answer is "let the model finish its summary", not "diversify to mutation tools". See §11.
- **Trail a marker**: every recovery should write a `chat.recovery_injected` event to `ai-trace.ndjson` with the trigger name. Today the count of recoveries per session is invisible from logs.

**Owning path:** `compass/Services/CloudPipeline/ToolLoopHandler.swift`, `compass/Services/CloudPipeline/ToolLoopUtilities.swift`.

---

## 9. `ls` / `read` results aren't cached across recovery cycles

**Problem.** `ToolLoopHandler.swift:687-720` keeps a `readResultCache` keyed by `toolCallSignature(call)`. But this cache lives **inside the `while` loop scope** — it's wiped on every recovery iteration because the recovery path `continue`s *before* the cache population code runs, and even when it runs the new `toolCalls` array has new `id`s that may hash to different signatures (the signature includes the arguments dictionary serialization, which can drift if the model rephrases `path`).

Net effect: the model calls `ls .` 14 times in `BA0AF9…` and pays full roundtrip cost each time.

**Fix.**
- Promote the cache to a **session-scoped** `ToolResultCache` actor (e.g. one per `conversationId`). Lookup by `(toolName, canonical-args)`. Cache `ls`, `read`, `glob`, `search` for a short TTL (30 s) or until a mutation touches a path under the listed directory.
- Consult it *before* dispatching, not just after. Pre-populate from prior iterations in the same conversation.
- When the model re-issues a cached call, return the cached result **and** annotate it `(cached from prior call — you've already seen this)`, so the model stops asking.

**Owning path:** `compass/Services/CloudPipeline/ToolLoopHandler.swift:69-79`, new `compass/Services/Tools/ToolResultCache.swift`.

---

## 10. Initial system prompt has zero project-structure overview

**Problem.** `SystemPromptAssembler.assemble` injects a `repoMap` ("condensed symbol map") only when populated. For a WordPress project (or any project where indexing hasn't produced a useful repo map) the agent starts blind — no idea what `wp-content/plugins/` even exists, no idea which plugins live there.

For the `career-register` review the *optimal* first turn is:

```
1. ls wp-content/plugins/career-register/      → 5 files
2. read wp-content/plugins/career-register/career-register.php
3. read wp-content/plugins/career-register/includes/class-career-register.php
4. … (3 more reads of asset files)
5. emit review
```

Instead the agent spent 14 `ls` + 6 `glob` + 4 `search` exploring before it could read any file, because nothing in the prompt said *"this is a WordPress project; plugins live at wp-content/plugins/"*.

**Fix.**
- Generate a **lightweight project shape summary** on project open — independent of the full symbol index. Output looks like:

  ```
  Project shape (detected):
    type: wordpress
    root files: index.php, wp-config-sample.php, wp-login.php, …
    entry points: index.php, wp-load.php
    plugin dirs (wp-content/plugins/): career-register, multi-stage-signup, wp-signup-form, …
    theme dirs (wp-content/themes/): twentytwentyfive
    excluded from index: wp-admin/, wp-includes/, .git/
  ```
- Inject this into the system prompt unconditionally (small, ~500 tokens) regardless of whether the full repo map is built.
- Cheap to compute: one `FileManager.directoryEnumerator` at root + per-subdir depth 2, cached on disk.

**Owning path:** `compass/Services/SystemPromptAssembler.swift`, new `compass/Services/Indexing/ProjectShapeSummary.swift`.

---

## 11. `requestLikelyRequiresMutation` is a naive substring matcher

**Problem.** `ToolLoopHandler.swift:2824-2841`:

```swift
let mutationSignals = [
    "create ", "write ", "edit ", "modify ", "update ",
    "refactor ", "migrate ", "add ", "delete ",
    "remove ", "rename ", "implement "
]
return mutationSignals.contains { normalized.contains($0) }
```

Substring matching fires on every "update", "edit", "add", "remove" in casual English — e.g. *"could you **add** a note about reviewing the plugin?"* → mutation required. The recovery path then forces `mutationRecoveryTools` / `strictMutationExecutionTools` and the model gets a toolset that doesn't match the user's intent.

For the reviewed prompt (*"could you review career-register plugin … check if its finished …"*) no signal triggers directly — **but** `shouldForceInitialExecutionFollowup` (`:2875`) returns `true` because the response claims **work was performed without producing requested artifacts**, and the model is then pushed to keep "doing more" instead of writing the review.

**Fix.**
- Replace substring matching with a small classifier: either a 5-token LLM-judge call or a hand-tuned imperative-mood detector (verb at start of sentence + object). *"add a note"* (mutation) vs *"can you check what **added** this bug?"* (read-only).
- Add an explicit **read-only intent class**: prompts containing `review`, `audit`, `summarize`, `explain`, `critique`, `assess`, `evaluate`, `check if`, `look at`, `what does <X> do` should skip every mutation-recovery path entirely.
- The recovery path should respect `mode` (`.chat` is read-only by definition — yet `isAgentic == true` for chat now) and skip `requestLikelyRequiresMutation` when `mode == .chat`.

**Owning path:** `compass/Services/CloudPipeline/ToolLoopHandler.swift:2824-2841`, plus the call sites at `:297`, `:338`, `:422`, `:751`, `:772`, `:789`, `:1012`, `:1016`, `:1023`.

---

## 12. Search-result shape under-pages, then under-explains

**Problem.** `SearchProjectTool.formatResults` (`:217-234`) truncates to 20 matches per file with `… and N more matches in this file`. There's no way to ask for the remaining matches in *that specific file*. The page footer says `offset=Y max_results=N` — but `offset` is over the **flat global list**, which when raised to 200 shows the same first 200 entries (across all files) repeatedly.

The user reported: *"the search should be giving exactly what was found which file/path it is and which line so limit offset read can be used."* The current format prints `file` and `line`, but the line numbers aren't reliably aligned with the `read` tool's `start_line`/`end_line` framing — `search` shows `L12 [reference] const useState…` while `read` with `start_line=12 end_line=12` returns `"12: const useState…"`. The model has to mentally bridge the two.

**Fix.**
- Group by file but paginate **per-file**, not per-flat-list. Footers should read `use search query=… file=src/App.tsx offset=20 max_results=50 to see more in this file`.
- Print line numbers in **exactly the format `read` accepts** (just the integer, no `L` prefix), with a hint: `to read each match: read path="<file>" start_line=<line> end_line=<line>`.
- Drop the 20-per-file cap in favor of explicit pagination everywhere. The current "… and N more matches" buries matches the model needs.

**Owning path:** `compass/Services/Tools/SearchProjectTool.swift:217-234`.

---

## 13. The `write` tool whole-file replaces — should diff

**Problem.** `WriteFileTool.execute` calls `FileToolWriteApplier.applyWrite` with the *entire* new file content (`WriteFileTool.swift:95-104`). Even when only one line changed, the entire file is sent in the tool arguments and re-written on disk. For a 2 000-line file this is ~30 k tokens of `content` per edit, repeated per roundtrip. The 180 k-token session in `BA0AF9…` was inflated by exactly this pattern (model would re-emit large files in `write` calls).

The model *also* uses `write` when `edit` would suffice, because `edit` requires a prior `read` (per `FileFileWriteApplier.swift:66`) and the model thinks writing the whole file is faster than reading first.

**Fix.**
- Once §1 lands (`edit` with `old_string`/`new_string`), down-rank `write` in the prompt: *"use `write` to create a NEW file. For any change to an EXISTING file, use `edit`."* Mirror this in the schema description.
- Make `write` to an existing file **refuse with a clear pointer**: `Refused: file exists. Use edit with old_string/new_string — see edit docs.` (Today it over-silently overwrites after a read.)
- After applying a `write`, return a one-line diff summary so the trace shows what changed, not just "wrote 12 k bytes".

**Owning path:** `compass/Services/Tools/WriteFileTool.swift:89-93`, `compass/Services/Tools/FileToolWriteApplier.swift`.

---

## 14. `bash` is mis-used for codebase exploration

**Problem.** `bash.md` itself says: *"For codebase exploration use `ls`, `read`, `search`, or `glob` instead."* `tool-system-prompt-full.md:30` repeats it. Real session: **49 of 79 tool calls** were `bash` — almost all running `find`/`grep`/`ls` that `glob`/`search`/`ls` should have done. The tool name is even mismatched (`bash` vs the alias `run_command` the docs mention).

Why does the model reach for `bash`? Three reasons:
1. The index (§7) is poisoned so `search` returns noise.
2. The recovery loop keeps swapping the toolset (§8) so the model loses faith in `search`/`glob`.
3. `bash` is the only tool that lets the model chain commands in one call — `find … -exec grep …`. The atomic `ls`/`search`/`read` roundtrip count feels higher.

**Fix.**
- Fix §7 (index poisons) and §8 (amnesia) — these alone will reduce `bash` use dramatically.
- Soft-block `bash` invocations that are obviously exploration: a deny-list regex (`^find\s`, `^grep\s`, `^rg\s`, `^ls\s.*-R`, `fd\s`, `tree\s`) returns a redirect: *"This is a codebase-exploration command. Use the `search`/`glob`/`ls` tools instead"* — with the corresponding tool call example pre-filled in the reply. Hard-block only after 2 such retries.
- Make this explicit in the `bash` schema description (the one-line field), not just the markdown.

**Owning path:** `compass/Services/Tools/TerminalTools.swift:413` (description), plus an exploratory-command detector in `validateCommand` (`:149-162`).

---

## 15. The `mode` docs describe mutation tools first; nothing says "review is read-only"

**Problem.** `mode-coder.md` opens with "you have full tool access and all rights". For a review-style prompt the model has no signal that just *reading and writing prose* is a valid deliverable. Combined with §11, the model assumes it must produce file changes and loops trying to "do work" — then the recovery loop fires because no mutation happened, the model gets pushed toward `strictMutationExecutionTools`, and we are back in amnesia.

**Fix.** Add a section to `mode-coder.md`:

```
## Read-only deliverables

Some requests ask for analysis, review, or explanation rather than file
changes. Treat these as fully legitimate outcomes:

- "review", "audit", "assess", "critique", "explain", "summarize":
  read the relevant files, then WRITE THE REVIEW as your final assistant
  message. Do NOT call `write`/`edit` to produce a markdown report
  unless the user explicitly asks for a file.

The reflection footer should be `Delivery: done` once your analysis
covers everything the user asked about.
```

**Owning path:** `Prompts/System/mode-coder.md`, `Prompts/System/mode-chat.md`.

---

## Cross-cutting recommendations

These are not single-file fixes — they require coordinating prompt + tool + telemetry:

1. **Make `tool-system-prompt-full.md` the *only* prompt.** Collapse `tool-system-prompt-concise` into the full one. The concise variant leaves out the very guardrails this session needed (read-before-write rule, `search` priority over `bash`). The 1.5 k-token savings isn't worth it.

2. **Single-source tool definitions.** Today a tool's name, parameters, description, and "how to use" prose are scattered across:
   - `compass/Services/Tools/<Tool>.swift` — `name`, `description`, `parameters` (the JSON schema)
   - `Prompts/Tools/v3/<tool>.md` — narrative doc read into the system prompt
   - `Prompts/System/mode-*.md` — per-mode mentions (often with legacy names)
   - `Prompts/System/tool-system-prompt-full.md` — high-level guidance
   - `ConversationToolProvider.swift` — assembly of available tools

   Drift between these is the source of §3, §4, §13, §14. Render `Tools/v3/*.md` from a single template populated from the schema at build time. Codegen, not authoring.

3. **Add a `chat.recovery_injected` telemetry event.** Every recovery path should write its trigger name and the iteration count. Right now the only signal is the model re-saying *"Let me start by exploring…"* 15 times — invisible to the operator.

4. **Adopt a "cost budget" per session.** Track cumulative tool calls + cumulative message characters; surface to the model in the tool-loop context: *"You have used 42 tool calls and 60 k tokens; the user asked for a single review. Consider summarizing."* This single nudge would have ended the `BA0AF9…` session after iteration ~10.

5. **Run the WordPress scenario as an offline harness.** Snapshot `~/Projects/WordPress/wp-content/plugins/career-register` into the test corpus and assert:
   - `search "career-register"` returns matches only under `wp-content/plugins/career-register/`
   - the agent emits ≤ 8 tool calls for "review this plugin"
   - 0 `bash` calls during discovery
   - final assistant message contains "production" or "ready"
   This is the regression test that would have caught every issue in this report before it shipped.

---

## Files to change (one-glance index)

| File | Section(s) | Change |
|---|---|---|
| `compass/Services/Tools/PatchFileToolAdapter.swift` | §1 | Add `old_string`/`new_string` mode |
| `compass/Services/Tools/FileToolWriteApplier.swift` | §1, §13 | Refuse whole-file overwrite of existing files in favour of `edit` |
| `compass/Services/Tools/WriteFileTool.swift` | §13 | Tighten description, refuse if file exists |
| `compass/Services/Tools/SearchProjectTool.swift` | §2, §12 | Honest description, per-file pagination, drop the 20-per-file cap |
| `compass/Services/Tools/FindFileTool.swift` | §5 | Make `path` optional, default to project root |
| `compass/Services/Tools/TerminalTools.swift` | §6, §14 | Detector for exploration commands, cwd in description |
| `compass/Services/Tools/ToolTaxonomy.swift` | §9 | Cache `ls`/`read`/`glob`/`search` results |
| `compass/Services/CloudPipeline/ToolLoopHandler.swift` | §8, §9, §11 | Preserve prior-work summary in recoveries, rate-limit, read-only intent |
| `compass/Services/SystemPromptAssembler.swift` | §10, cross-cutting 2 | Inject project shape; collapse concise/full prompt |
| `compass/Services/Indexing/*` (new) | §7, §10 | Framework-aware `index_exclude`, project-shape summary |
| `Prompts/System/mode-coder.md` | §3, §15 | Canonical tool names, read-only deliverables section |
| `Prompts/System/mode-chat.md` | §3, §15 | Same |
| `Prompts/System/project-root-context.md` | §6 | Explicit bash-cwd section |
| `Prompts/System/tool-system-prompt-concise.md` | cross-cutting 1 | Delete; route everything to `-full` |
| `Prompts/Tools/v3/read.md`, `v3/glob.md`, `v3/bash.md`, `v3/edit.md`, `v3/search.md`, `v3/ls.md` | §4 | Reconcile with schemas; ideally codegen |
| `compass/Services/ToolAliasRegistry.swift` | §3 | Keep as invisible fallback only; no prompt-level mention of legacy names |

---

## Sanity-check: predicted behavior after fixes

For the same `review career-register plugin` prompt:

1. System prompt now contains `Project shape (detected): wordpress, plugins: career-register, …`.
2. `mode-coder.md` permits read-only deliverables.
3. Model calls `ls wp-content/plugins/career-register/` once. Tool cache populated.
4. Model calls `glob "**/career-register/**"` once (no `path` required) — gets the 5 files.
5. Model calls `read` on each of the 5 files — 5 calls.
6. Recovery loop sees read-only intent; never asks for mutation; never fires amnesia.
7. Model emits final review assistant message, `Delivery: done`.

**Predicted cost: 1 `ls` + 1 `glob` + 5 `read` = 7 tool calls, ~10 s, ~5 k tokens.** Matches the user's expectation.