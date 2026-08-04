## context — Retrieve prior conversation context from the knowledge store

**When to use:** After context has been trimmed (you'll see a notice). When you need to recall prior findings, decisions, or code patterns from earlier in this session or previous sessions.

**Parameters:**
- query (required, string): What you need to recall. Be specific about the topic, file, or decision.
- max_results (optional, integer): Max results to return (1-10, default 5).

**Expected output:** Plain text. Optionally a `session context:` block (plan progress, files read this session), then `status:`, `message:`, and a `content:` block listing `items:` as indented `- result N:` entries, each with `source:` and `text:` (truncated to ~500 chars). When nothing matches, `content: items: []`.
Example:
```
status: success
message: Found 2 relevant result(s).
content:
  items:
    - result 1:
      source: src/App.tsx
      text: The App component renders the todo list and...
```
Read the text directly. The actual fields are `source` and `text` (there is no `timestamp` or `relevance` field, and no nested JSON `content.items` array).

**Recovery:**
- No results: Try a different query — use more specific terms or keywords from the prior work.
