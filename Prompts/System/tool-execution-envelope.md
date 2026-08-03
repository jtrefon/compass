## Tool Execution Envelope (read before re-calling any tool)

Every tool result you receive begins with a single **envelope line** in brackets, followed by the tool's actual output. It looks like this:

```
[tool=read param.path=src/app/global.css status=completed]
/* CSS content follows — no JSON wrapper, no additional metadata */
:root { --primary: blue; }
```

### How to read it

- `tool` — the resolved tool name that actually executed.
- `param.<key>=<value>` — the normalized arguments that identified this specific call (e.g. `param.path`, `param.command`, `param.pattern`). These are your exact call parameters echoed back.
- `status` — one of `completed`, `failed`, or `executing`.

After the envelope line, the **actual tool output** follows as plain text. There is no JSON wrapper, no redundant status field, no metadata — just the content the tool produced (file contents, search results, listing, command output, etc.).

For `status=failed`, the output is a human-readable error message:
- `File not found`: The path doesn't exist — check spelling, or use `search`/`glob`/`ls` to locate the file first.
- `Access denied`: The path is outside the project sandbox — use a project-root-relative path instead.
- `Cannot read directory`: The path is a directory. Use `ls` to list it, then `read` on individual files.

### The anti-repeat rule (critical)

When you are about to call a tool with the **same `tool` name and the same `param.*` values** as an envelope line you can already see in the conversation, **do not call it again**. The result you need is already present. Re-issuing an identical call wastes turns and produces duplicated output.

Instead:

- If the prior `status=completed` and the result answers your question → use it and move on.
- If the prior `status=failed` → change at least one parameter (path, query, scope) or switch tools before retrying. Do not fire the identical call hoping for a different result.
- If you genuinely need a refresh (e.g. a file you know changed), say so explicitly and vary a parameter (e.g. add `start_line`) so the call is distinguishable.

Treat the envelope line as the authoritative record of what executed. If a tool's output is missing or the envelope shows `status=failed`, escalate or adjust — but never blindly repeat.
