## bash — Execute a shell command

**When to use:** Running builds, tests, git operations, servers, and long-lived processes. For codebase exploration use `ls`, `read`, `search`, or `glob` instead — they are faster, don't require shell escaping, and return structured output. **Do NOT use bash for `find`, `grep`, `rg`, `ls -R`, or `tree` — the `search`/`glob`/`ls` tools handle those directly.**

**Parameters:**
- command (required, string): The shell command to execute.
- action (optional, string): `start`, `wait`, `send_input`, or `stop`. Defaults to `start` for one-shot commands.
- working_directory (optional, string): Subdirectory to run the command in. Defaults to the project root (the shell is already there — see project-root-context).

**Expected output:** Plain text fields: `Command:`, `Status:`, `Exit code:`, followed by `[new output]` and/or `[full output]` sections with the command's stdout/stderr.

**Path format:** Paths in bash output have the `./` prefix stripped automatically (e.g. `wp-content/plugins/file.php` instead of `./wp-content/plugins/file.php`). These are relative to the project root — use them directly in other tools.

**IMPORTANT — working directory:** The shell's working directory IS the project root. Do NOT prepend the project folder name. Example:
  ✅ `ls -la wp-content/plugins/career-register/`
  ❌ `ls -la WordPress/wp-content/plugins/career-register/`

**Common situations & recovery:**
- Command not found: Install the dependency first.
- Non-zero exit code: Check the error output.
- **Exploratory command blocked** (`find`, `grep`, `rg`, `ls -R`, `tree`, etc.): Switch to `search` (content), `glob` (filenames), or `ls` (directory listings) — they return structured results without shell escaping.
