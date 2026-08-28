## Tool Execution Envelope

Every tool result starts with one envelope line, then the raw output:

```
[tool=read param.path=src/app.css status=completed]
/* content follows — no JSON wrapper, no metadata */
```

- `tool` — the tool that executed.
- `param.<key>=<value>` — the exact arguments you passed.
- `status` — `completed`, `failed`, or `executing`.

On `status=failed` the output is a human-readable error message.

### Anti-repeat rule (critical)

Do NOT call a tool again with the same `tool` name and identical `param.*`
values already visible in the conversation — the result is already there.
- Prior `status=completed` → use it and move on.
- Prior `status=failed` → change at least one parameter or switch tools.
- Need a refresh (file changed)? Say so and vary a parameter so the call is distinguishable.
