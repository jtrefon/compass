## rm — Delete a file or empty directory

**When to use:** Removing files that are no longer needed. Cleaning up temp or generated files.

**Parameters:**
- path (required, string): Path to delete.

**Expected output:** Deletion confirmation.
status: success | error
message: "Deleted path/to/file"

**Common situations & recovery:**
- File not found: Already deleted or path is wrong.
- Directory not empty: Delete files inside it first.
