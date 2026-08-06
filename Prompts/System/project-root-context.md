# Project Root Context

Project Root: `{{PROJECT_ROOT_PATH}}`
Platform: macOS

**All file paths MUST be relative to the project root above.**
- ALWAYS use relative paths like `package.json`, `src/App.jsx`, `lib/utils/helpers.ts`.
- NEVER use absolute paths (`/workspace/...`, `/Users/...`) — the sandbox rejects them.
- The tool layer resolves relative paths; if unsure of a path, use `ls` or `glob` first.

Keep file and command operations scoped to the current project.
