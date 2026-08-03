## write — Create a new file or completely overwrite an existing one

**When to use:** Creating NEW files, or fully replacing an existing file with new content. This is how you actually produce the artifacts the user asked for (new modules, configs, tests). For targeted changes to an existing file, use `edit` instead.

**Parameters:**
- path (required, string): Absolute path, or a path relative to the project root. This argument is REQUIRED — a write without a `path` fails.
- content (required, string): The full content to write.

**Expected output:** Status confirmation with byte count.
status: success | error
message: "Created path/to/file (123 bytes)"

**Common situations & recovery:**
- "Missing 'path'": include a non-empty `path` (absolute or project-root-relative). Example: `src/components/TodoInput.tsx`.
- File already exists with content you want to keep: use `edit` for a targeted change instead of overwriting.

**Quality (MANDATORY):**
- Write the COMPLETE implementation in one shot — never a placeholder, skeleton, or TODO stub. A file full of "Placeholder" comments is a failed write.
- After writing, verify the file: run a syntax check (e.g. `php -l <path>` for PHP), read the file back, and confirm it does what was intended.
