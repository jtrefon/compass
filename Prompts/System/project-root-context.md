# Project Root Context

Project Root: `{{PROJECT_ROOT_PATH}}`
Platform: macOS

**CRITICAL: All file paths MUST be relative to the project root above.**
- NEVER use absolute paths like `/workspace/`, `/home/`, `/Users/`, `/var/`, or `/tmp/`.
- ALWAYS use relative paths like `package.json`, `src/App.jsx`, `src/main.ts`.
- The tool layer will resolve relative paths to the correct absolute location.
- If you need to know the current working directory, call `ls .` or `pwd`.
- Attempting to write to `/workspace/...` or `/home/...` will fail with a sandbox error.

Examples of CORRECT paths:
- `package.json` ✓
- `src/App.jsx` ✓
- `lib/utils/helpers.ts` ✓

Examples of WRONG paths:
- `/workspace/package.json` ✗
- `/home/user/project/src/App.jsx` ✗
- `/Users/name/project/package.json` ✗

Keep file and command operations scoped to the current project. Do not invent Linux-style paths.

## Shell working directory (READ THIS — most common mistake)

The `bash` tool launches its shell **with cwd already at the project root above** — every command starts INSIDE the project folder. You don't need to `cd` in, and you must NOT prepend the project's folder name to paths.

CONCRETE EXAMPLE — if Project Root is `/Users/jack/Projects/WordPress`:
  ✅ CORRECT: `ls -la wp-content/plugins/career-register/`
  ✅ CORRECT: `cat wp-config-sample.php | head -5`
  ✅ CORRECT: `find wp-content/plugins -name "*.php" -type f`
  ❌ WRONG:   `ls -la WordPress/wp-content/plugins/career-register/` (file `WordPress` does not exist — the shell is already inside `WordPress`)
  ❌ WRONG:   `cd WordPress && ls wp-content/plugins/`        (no such directory to cd into)
  ❌ WRONG:   `ls /Users/jack/Projects/WordPress/wp-content/` (absolute paths waste tokens and may be rejected)

**Recovery from `file does not exist` errors**: if a `bash` call fails with `The file "X" doesn't exist` where `X` is the project's own folder name, you prepended the project folder. Drop the leading `X/` segment and re-issue the command. **Do not retry the same rejected path** — it will fail identically.

For everything except shell commands (`read`, `write`, `edit`, `ls`, `glob`, `search`), pass paths relative to the same project root — the tool layer resolves them.
