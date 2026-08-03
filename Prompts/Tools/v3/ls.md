## ls — List files and directories

**When to use:** Exploring project structure. Finding files when you know part of the name.

**Parameters:**
- path (optional, string): Directory to list. Defaults to current directory.
- filter (optional, string): Case-insensitive name substring filter.
- limit (optional, integer): Max entries to return (default 200, max 1000).
- offset (optional, integer): Number of entries to skip for pagination (default 0).

**Expected output:** Plain text, one entry per line — the name of each file or directory (with ` (excluded)` appended when filtered out). For full paths use `glob`.
Example:
```
src
index.html
package.json (excluded)
```
Read the list directly from the text. There is no nested JSON `content.items` field.

**PAGINATION:** When results show a `[showing X-Y of Z — use offset=Y limit=N for the next page]` footer, call the tool again with the suggested offset to get the next page. Repeat until all entries are seen.
