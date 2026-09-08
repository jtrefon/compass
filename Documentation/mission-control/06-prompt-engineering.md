# 06 — Prompt Engineering

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Overview

The system needs new and updated prompts to teach the model how to use Mission Control, the `note` tool, and context discipline. This document specifies the exact prompt additions and modifications.

---

## 2. New Prompt: Context Discipline

Create `Prompts/System/context-discipline.md`:

```markdown
# Context Discipline — Your Memory Is Finite

## The Reality

Your context window is not infinite. Every file you read, every search result, every command output stays in your context until a reset happens. If you explore carelessly, you will run out of space before you can act.

## Your Memory System

You have three layers of memory:

1. **Working Memory (notes)** — Persistent. You write findings via the `note` tool. These survive context resets. This is your primary memory.
2. **Key Excerpts** — Automatic. The system selects relevant code chunks from your tool results. These appear in Mission Control.
3. **Cold Storage** — Unlimited. Everything you've ever read is stored with embeddings. Retrieve via the `context` tool when you need something you didn't note.

## Mission Control

At the end of every turn, you see a `## MISSION CONTROL` block. It contains:
- Your goal and plan progress
- Your working memory (notes you've written)
- Key excerpts (relevant code chunks)
- Your context budget (how much space you have left)

Read it. It's your state. It tells you what you know and how much space you have.

## The Note Discipline

### After EVERY read, write a note

```
read("PaymentService.php", limit=30)
→ [tool returns 30 lines of code]
note(action="add", section="PaymentService", intent="finding",
     content="Stripe+PayPal. processPayment() L34. NO amount validation (RISK). Hardcoded key in constructor (CRITICAL).")
```

### Note format

- **1-3 sentences.** Not a paragraph. Not a code dump.
- **Include file:line references.** You can re-read specific lines later if needed.
- **Note risks explicitly.** Use (RISK), (CRITICAL), (GOOD) tags.
- **Don't copy code.** Reference it by file:line. The code is in cold storage.

### Intent matters

- `intent="finding"` — You read to understand. The raw read becomes disposable after noting. Your note preserves the knowledge.
- `intent="edit_target"` — You read to edit. The raw read is preserved through context resets. Use this before editing.

### When NOT to note

- Trivial reads (config files, package.json with obvious content)
- Reads you immediately act on (read → edit in the same turn)
- Search results that weren't useful

## Context Budget Awareness

Mission Control shows your context budget:

- **< 25% used** — Explore freely, but take notes.
- **25-50% used** — Be surgical. Use `limit=20-30` on reads. Note after every read.
- **50-75% used** — Stop exploring. You have notes — act on them.
- **> 75% used** — A context reset is imminent. Ensure all critical findings are noted. Your notes will survive; raw reads will not.

## After a Context Reset

If you see `## Context Reset` in your history:
1. Read Mission Control — it has your goal, plan, and all your notes.
2. Do NOT re-explore files you have notes on. Your notes have what you need.
3. If you need specific code, use surgical reads: `read("file.php", start_line=34, end_line=45)`.
4. If you need something you didn't note, use `context("what you're looking for")` to retrieve from cold storage.
5. Continue working. The reset freed space for you to act.

## Anti-Patterns

- ❌ Reading 10 files without noting any of them
- ❌ Re-reading a file you already have a note on
- ❌ Writing notes that copy code (use file:line references instead)
- ❌ Ignoring the context budget
- ❌ Exploring when context is > 75% full
- ❌ Noting every trivial read (use judgment — note what matters)

## The Expert Mindset

An expert doesn't memorize the entire codebase. They understand the architecture, know where to find details, and keep a mental notebook of findings. You are that expert. Your `note` tool is your notebook. Use it like one.
```

---

## 3. Mode Prompt Modifications

### 3.1 mode-coder.md

Add the context discipline section and note tool to `Prompts/System/mode-coder.md`:

**Change 1: Add `note` to Available Tools**

```
## Available Tools

read, write, edit, rm, search, bash, plan, note, context, web_search, web_fetch
```

**Change 2: Add Context Discipline Reference**

After the "Structured Task Planning" section, add:

```markdown
## Context Discipline & Working Memory

Your context window is finite. Every tool result stays in context until a reset happens. To work effectively:

1. **Take notes after every read.** Call `note()` with a compact finding (1-3 sentences, include file:line references). Your notes survive context resets; raw tool results do not.
2. **Declare intent.** Use `intent="finding"` for code read to understand (raw read becomes disposable). Use `intent="edit_target"` for code you're about to edit (raw read is preserved).
3. **Watch your context budget.** Mission Control (at the end of every turn) shows how much context you have left. When it says > 75%, stop exploring and start acting.
4. **After a context reset**, read Mission Control — it has your goal, plan, and all your notes. Don't re-explore; work from your notes.

See `context-discipline.md` for the full discipline.
```

**Change 3: Update Research Discipline section**

Replace the existing "Research Discipline & Momentum" section with:

```markdown
## Research Discipline & Momentum

- **Research supports writing — it is never the deliverable.** Use search and read to understand the codebase or an API you must target, then WRITE the artifacts. Do not treat `web_search`, `web_fetch`, or file reads as progress on their own.
- **Note as you go.** After every `read` or `search` that reveals something, call `note()` immediately. Don't batch notes — write them while the content is fresh. Your notes ARE your memory.
- **Cap external research.** At most a couple of targeted lookups for an unfamiliar API; if a result isn't immediately actionable, stop and make a reasonable decision. Never loop on `web_search`/`web_fetch` — each cycle burns context and delays delivery.
- **Be surgical with reads.** Use `limit=20-30` for initial reads. Use `start_line`/`end_line` for specific sections. Don't read entire files when you need one function.
- **Commit to writing.** Once you can name the files a task requires (config, entry point, tests), write them. If a detail is uncertain, write a minimal valid version and refine it — a file on disk beats another round of research.
- **Keep momentum.** After every tool result, take the next concrete step toward a deliverable. If you genuinely have no next action, write down the remaining work and your plan rather than spinning on more searches.
```

### 3.2 mode-agent.md

Apply the same changes as mode-coder.md. The agent mode has full tool access, so `note` is available.

### 3.3 mode-chat.md

**No changes.** Chat mode is read-only Q&A — no persistent working memory needed. The `note` tool is not available in chat mode. Mission Control is not injected in chat mode (no notes to render, no plan to track).

---

## 4. New Tool Prompt: note.md

Create `Prompts/Tools/v3/note.md`:

```markdown
## note — Working Memory

### WHAT
Write a finding to your persistent working memory. Notes survive context resets; raw tool results do not.

### WHEN
- After EVERY `read` call — capture what you learned
- After `search` results that reveal structure — capture the key findings
- After `bash` output that reveals build/test status — capture the result
- Before a context reset — ensure all critical findings are noted
- NOT for code you're about to edit (use intent='edit_target' instead)

### HOW
- action: "add" (new note), "update" (revise section), "clear" (remove section)
- section: Use file names for file-specific findings, "architecture" for structure, "risks" for issues, "decisions" for choices
- content: 1-3 sentences. Include file:line references for later surgical re-reads. Note risks with (RISK) or (CRITICAL). Do NOT copy code — reference it by file:line.
- intent: "finding" (read to understand — raw read disposable after noting) or "edit_target" (read to edit — raw read preserved through context resets). Defaults to finding.

### OUTPUT
status: success | duplicate | error
message: confirmation with note count

### EXAMPLES

After reading PaymentService.php:
```
note(action="add", section="PaymentService", intent="finding",
     content="Stripe+PayPal. processPayment() L34. NO amount validation (RISK). Hardcoded key in constructor (CRITICAL).")
```

Before editing checkout.js:
```
note(action="add", section="checkout.js", intent="edit_target",
     content="Need to add amount validation at L23 before processPayment call.")
```

Updating a section with new findings:
```
note(action="update", section="PaymentService", intent="finding",
     content="Reviewed: hardcoded Stripe key (CRITICAL), no amount validation (RISK), no webhook signature verification (CRITICAL).")
```

### RULES
- 1-3 sentences per note. Not a paragraph.
- Include file:line references. Don't copy code.
- Note risks with (RISK), (CRITICAL), (GOOD) tags.
- If you get `status: duplicate`, use `action: "update"` instead of "add".
- Your notes ARE your memory. If you don't note it, you lose it on reset.
```

---

## 5. SystemPromptAssembler Integration

### 5.1 Add context-discipline.md to system prompt

In `SystemPromptAssembler` (or equivalent), add `context-discipline.md` to the assembled system prompt for coder and agent modes:

```swift
// In SystemPromptAssembler.assemble():
let systemPromptFiles: [String] = [
    "System/base-system-prompt",
    "System/tool-system-prompt-full",  // or -concise based on config
    "System/tool-execution-envelope",
    "System/mode-\(mode.rawValue)",     // mode-coder, mode-agent, mode-chat
    "System/context-discipline",        // NEW — only for coder/agent
    "System/project-root-context"
]

// Filter: context-discipline only for agentic modes with note tool
let filteredFiles = mode == .chat
    ? systemPromptFiles.filter { $0 != "System/context-discipline" }
    : systemPromptFiles
```

### 5.2 Add note.md to tool prompts

Add `"Tools/v3/note"` to the `toolPromptKeys` array:

```swift
let toolPromptKeys: [String] = [
    "Tools/v3/read",
    "Tools/v3/write",
    "Tools/v3/edit",
    "Tools/v3/rm",
    "Tools/v3/search",
    "Tools/v3/bash",
    "Tools/v3/plan",
    "Tools/v3/note",       // NEW
    "Tools/v3/web_search",
    "Tools/v3/web_fetch"
]
```

For chat mode, `note` is filtered out (not in the allowed tools list).

---

## 6. Prompt Token Budget

### 6.1 Current System Prompt Size

The current system prompt (base + tools + envelope + mode + project shape) is approximately:
- Base system prompt: ~1K tokens
- Tool prompts (10 tools × ~200 tokens): ~2K tokens
- Tool execution envelope: ~500 tokens
- Mode prompt (coder): ~800 tokens
- Project shape summary: ~500 tokens
- **Total: ~4.8K tokens**

### 6.2 With Mission Control Additions

- Context discipline prompt: ~600 tokens
- Note tool prompt: ~300 tokens
- **New total: ~5.7K tokens**

This is a ~18% increase in system prompt size. On a 30K context, this is ~19% of the budget (vs ~16% currently). The investment is justified: the prompt teaches the model to manage its own context, which saves far more than 900 tokens per task.

### 6.3 Mission Control Block Size

Mission Control is injected as the last user message, not in the system prompt. Its size varies:

| State | Mission Control size |
|---|---|
| Empty (no plan, no notes) | ~200 tokens |
| Early task (plan + 2-3 notes) | ~800 tokens |
| Mid task (plan + 8 notes + 3 excerpts) | ~1.8K tokens |
| Late task (plan + 15 notes + 5 excerpts) | ~2.8K tokens |

Mission Control is rebuilt every turn, so only the latest one matters for context cost. Previous turns' Mission Control messages remain in history but are evicted during resets.

---

## 7. Check-Prompts Validation

The existing `./run.sh check-prompts` script validates prompt files. The new prompts must pass:

```bash
./run.sh check-prompts
```

This validates:
- All referenced prompt files exist
- No circular references
- Token counts are within budget
- Mode-specific filtering is correct

The new files to validate:
- `Prompts/System/context-discipline.md`
- `Prompts/Tools/v3/note.md`
- Modified: `Prompts/System/mode-coder.md`
- Modified: `Prompts/System/mode-agent.md`

---

## 8. Prompt Iteration

The context discipline prompt is the most critical new prompt. If the model doesn't take notes, the entire system fails. We should:

1. **Start with the prompt as specified above.**
2. **Run benchmark tasks** (see [07-implementation-plan.md](07-implementation-plan.md)) and observe note-taking behavior.
3. **Iterate the prompt** based on:
   - Is the model taking notes after reads?
   - Are notes compact (1-3 sentences) or verbose?
   - Is the model using `intent="edit_target"` correctly?
   - Is the model responding to context budget guidance?
4. **A/B test prompt variations** if needed (e.g., stronger language, different examples).

The prompt is the human-AI interface for this system. It deserves the same iteration attention as any UX.
