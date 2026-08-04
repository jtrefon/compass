## glob — Find files by name pattern

**When to use:** Finding files by name — no prior `ls` needed. Searches from the project root by default. Quick lookup before reading or editing.

**Parameters:**
- pattern (required, string): Filename substring to search for (e.g., "career-register", "ProfileView"). Partial matches allowed — any filename containing the pattern will be returned. This is NOT a glob pattern — use a plain name substring.
- path (optional, string): Subdirectory to scope the search (e.g. "wp-content/plugins"). Omit to search the entire project root.
- max_results (optional, integer): Max file names to return (default 50, max 200).
- offset (optional, integer): Number of results to skip for pagination (default 0).

**Expected output:** Plain text. A header `Found N file(s):` followed by one matching file path per line.
Example:
```
Found 2 file(s):
career-register/career-register.php
career-register/includes/class-career-register.php
```
Read the paths directly from the text. There is no nested JSON `content.items` field.

**PAGINATION:** When results show a `[showing X-Y of Z — use offset=Y max_results=N for the next page]` footer, call the tool again with the suggested offset to get the next page.
