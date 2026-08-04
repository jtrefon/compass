## search — Understand an existing codebase: symbols, text, filenames

**When to use:** The FIRST tool whenever you need to understand code that already exists — before you change it. Use it to map the project's structure, find where a function/class/variable is defined or used, and locate files by content or name. It combines symbol lookup, the full-text index (FTS5), and a filesystem grep fallback. Results come from the project's pre-built index — fast and comprehensive even on large codebases.

**Parameters:**
- query (required, string): The code, symbol, or text to search for.
- max_results (optional, integer): Max results per page (default 50, max 200).
- offset (optional, integer): Number of results to skip for pagination (default 0).

**Expected output:** Plain text. A header `Found N occurrence(s) of "<query>":` followed by matches grouped by file (each file under a `# <path>` line), with the line number (`<line>:`), a bracketed match type (e.g. `[reference]`, `[class]`, `[function]`), and the matching line content. No truncation per file — all matches are shown.
Example:
```
Found 3 occurrence(s) of "useState":

# src/App.tsx
  12: [reference] const [count, setCount] = useState(0)
  20: [reference] useState(saved)

# src/hooks.ts
  4: [reference] export function useState<T>(...)
```
Read the matches directly from the text. There is no nested JSON `content.items` field.
Use `read path="{file}" start_line={line} end_line={line}` to see full context around any match.

**PAGINATION:** When results show a `[showing X-Y of Z — use offset=Y max_results=N for the next page]` footer, call the tool again with the suggested offset to get the next page. Repeat until no more pages.

**Common situations & recovery:**
- Before a refactor/migration: search the project first to enumerate every file and symbol you will touch.
- No results: Try a broader query, or part of the name.
