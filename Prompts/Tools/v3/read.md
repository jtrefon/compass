## read — Read file contents with optional line range

**When to use:** Reading files. `read` only works on files, not directories — use `search` to find the file path first.

**Parameters:**
- path (required, string): Project-root-relative path to the file.
- start_line (optional, integer): 1-based start line. Omit for line 1.
- end_line (optional, integer): 1-based end line (inclusive). Omit to read to EOF.
- char_offset (optional, integer): 0-based character offset for minified/single-line files (use with char_limit).
- char_limit (optional, integer): Number of characters to return when using char_offset.

**Expected output:** File content with line numbers. Line count and size in status.
status: success | error
content.text: file content (line-numbered when using start_line/end_line)

**PAGINATION:** Large files return a `(Showing lines X-Y of Z. Use start_line=Y+1 end_line=<chunk> to continue.)` footer. Always follow this footer to read the next chunk rather than re-reading from the beginning.

**Common situations & recovery:**
- Path is a directory: Use `search` (filenames) to find the files inside — `read` only opens files.
- File not found: Use `search` to locate it first.
- File is large: Use start_line/end_line to read only the range you need. The line numbers map directly to edit parameters.
