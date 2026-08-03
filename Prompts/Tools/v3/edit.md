## edit — Edit an existing file (locate-and-replace preferred)

**When to use:** ALL modifications to existing files. This is the primary mutation tool.

The tool has two modes. **Use old_string/new_string whenever possible** — it does not require a prior `read` and refuses ambiguous matches, so it is safer and more context-efficient than line-range edits.

### Mode 1 — `old_string` / `new_string` (preferred)

Pass `old_string` (the exact text to find in the file) and `new_string` (the replacement). The tool locates the match itself — you do NOT need to `read` first.

- The match is an **exact byte comparison**. Copy the substring precisely, including indentation and newlines. If you're unsure of the exact text, read the file once first.
- `old_string` must match **exactly once** by default. If it matches 0 times, the tool returns `OLD_STRING_NOT_FOUND`; if it matches more than once, the tool returns `AMBIGUOUS_MATCH` and asks you to add more surrounding context.
- Set `replace_all: true` to replace every occurrence in one call (skips the uniqueness check). Use sparingly.
- Pass `new_string=""` (empty) to delete the matched text.
- **`path` accepts a project-relative path** (e.g. `wp-content/plugins/my-plugin.php`).

### Mode 2 — `start_line` / `end_line` / `new_content` (line-range)

Use for whitespace-sensitive blocks the model can't quote reliably, or for whole-function rewrites where line numbers were already established by a `read`. You MUST `read` the file first to get current line numbers — line numbers from prior turns may be stale.

- `start_line` and `end_line` are 1-based, inclusive.
- `new_content` replaces the entire `start_line..end_line` range and may itself span multiple lines.

## Parameters

- path (required, string): project-root-relative path to the file.
- old_string (optional, string): locate-and-replace mode — exact text to find.
- new_string (optional, string): replacement text (paired with `old_string`).
- replace_all (optional, boolean): replace every occurrence of `old_string`. Default false.
- start_line (optional, integer): 1-based line where replacement begins (line-range mode).
- end_line (optional, integer): 1-based inclusive end line (line-range mode).
- new_content (optional, string): replacement text (paired with `start_line`/`end_line`).

**Requirement:** Provide either (`old_string` + `new_string`) OR (`start_line` + `end_line` + `new_content`). The old_string mode is preferred.

## Expected output

```
status: success | error
message: <summary>
content: <unified-diff preview>
```

## Common situations & recovery

- `OLD_STRING_NOT_FOUND`: copy the substring exactly from the file (use `read` if you don't have it). First check leading/trailing whitespace and trailing-newline differences.
- `AMBIGUOUS_MATCH`: include 1–3 extra lines of surrounding context in `old_string`, or set `replace_all=true` only if you genuinely want all matches changed.
- `INVALID_LINE_RANGE` (line-range mode): `read` the file again — it changed underneath you.
- `FILE_NOT_FOUND`: create with `write` instead.