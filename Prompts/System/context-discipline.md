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

- Reading 10 files without noting any of them
- Re-reading a file you already have a note on
- Writing notes that copy code (use file:line references instead)
- Ignoring the context budget
- Exploring when context is > 75% full
- Noting every trivial read (use judgment — note what matters)

## The Expert Mindset

An expert doesn't memorize the entire codebase. They understand the architecture, know where to find details, and keep a mental notebook of findings. You are that expert. Your `note` tool is your notebook. Use it like one.
