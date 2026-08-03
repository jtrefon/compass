## web_search — Search the web

**When to use:** Finding documentation, tutorials, error solutions. Researching libraries or APIs.

**Parameters:**
- query (required, string): The search query.

**Expected output:** Plain text. A header `Search results for: "<query>" (N results)` followed by one numbered entry per result, each showing a title, `URL:`, and a snippet. It ends with a hint to use `web_browse` (action=open) to read a specific page.
Example:
```
Search results for: "typescript strict config" (3 results)

[1] TypeScript tsconfig strict
    URL: https://www.typescriptlang.org/tsconfig
    strict mode requires noImplicitAny, strictNullChecks...

[2] Configuring Strict in TS
    URL: https://example.com/strict
    ...
Use web_browse with action=open and a url from above to read a specific page.
```
Read the results directly from the text above. There is no nested JSON `content.items` field — the result content is the text shown here.
