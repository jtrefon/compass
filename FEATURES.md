# Feature list to implement

This is a living backlog for our AI-enabled macOS IDE. Checked items are shipped; unchecked items are targets.

## Backlog guardrails (to avoid dead UI + chaos)
- **Command-first**: Every user action must map to a `CommandID` (so it can be triggered by menu, shortcut, UI buttons, and the agent).
- **No dead UI**: Never add menu items/toggles/buttons that do nothing. If a feature isn’t implemented, omit it from UI or hide behind a `FeatureFlag` (and default it off).
- **Single owner surface**: Every feature must name its primary UX surface (e.g., File Tree, Editor, Right Panel, Command Palette).
- **Deterministic concurrency**: Parallelize reads/search/indexing; serialize writes per-path; keep tool execution ordering deterministic in UI.
- **Reversible by default**: Any multi-file edit must be reversible (git OR checkpoints). Prefer “diff-first” review before writing.
- **Project-scoped state**: Anything project-specific lives under `.ide/` (history, plans, logs, checkpoints, staged diffs).
- **No in-IDE ticketing**: This file is backlog/spec documentation only; do not build an issue tracker/tickets UI inside the IDE.

## Architecture map (where changes go)
- **Commands**
  - Define `CommandID` constants in `Compass/Core/StandardCommands.swift` (or a new `*Commands.swift` grouped by area).
  - Register handlers in `Compass/Core/CorePlugin.swift` (or a future plugin module).
  - UI triggers call `CommandRegistry.shared.execute(...)` (no “inline” one-off handlers in views).
- **Sidebar / File Tree**
  - Main entry: `Compass/Components/FileExplorerView.swift` → `Compass/Components/ModernFileTreeView.swift`.
  - File system actions belong in workspace services (`Compass/Services/WorkspaceService.swift`).
- **Editor**
  - Main layout: `Compass/ContentView.swift`.
  - Text component: `Compass/Components/CodeEditorView.swift` (selection context already available).
  - File IO/state: `Compass/Services/FileEditorService.swift`.
- **Right panel**
  - Currently `ContentView` shows a single `.panelRight` view. If adding Inspector/Tasks/etc, prefer a single “RightPanelContainer” that hosts internal tabs (AI/Inspector/Tasks) to avoid competing plugins.
- **Agent + tools**
  - Tools live under `Compass/Services/Tools/` and conform to `AITool`.
  - Tool calls are executed by `Compass/Services/AIToolExecutor.swift`; keep it deterministic and UI-friendly.
- **Project persistence**
  - Chat: `.ide/chat/` (see `Compass/Services/ChatHistoryManager.swift`)
  - Plans: `.ide/plans/` (see `Compass/Services/Planning/ConversationPlanStore.swift`)
  - Logs: `.ide/logs/` + App Support logs (see `Compass/Services/Logging/*`)
  - Session UI state: `.ide/session.json` (see `Compass/Services/Session/*`)

## Language support framework (plugin-based; no single-language exceptions)

We support **multiple languages** through a single **capability-based language framework**. No language is allowed to bypass the framework, and we do not introduce architectural exceptions (e.g. “Swift gets special parsing”).

### Purpose
- Provide a scalable, extendable foundation for **language plugins**.
- Allow shipping language features incrementally (MVP highlighting → formatting/indentation → indexing/symbols → linting → language help).
- Keep the core IDE stable and language-neutral while plugins evolve.

### Non-negotiable boundaries
- No language-specific logic hardcoded into core flows (Editor/Search/Index/Navigation).
- No third-party/vendor language parsers embedded as required dependencies of the core IDE.
- Feature parity is driven by declared plugin capabilities; languages may be at different maturity levels, but they still go through the same extension points.
- When a capability is not implemented for a language, behavior must be:
  - predictable
  - explicitly “best-effort”
  - and must fail with a clear message (never silent incorrect results).

### Core concept: capabilities (not monolith plugins)

Each language module can implement one or more capabilities. This keeps the system robust and avoids “all or nothing” language support.

- **Language identification**
  - Map file extension(s) and/or content sniffing to a `CodeLanguage`.
- **Syntax highlighting**
  - Provide tokenization/rules used by the syntax highlighter.
  - Must be fast and safe for large files; fall back to a generic highlighter.
- **Indentation**
  - Provide indentation rules (tab/space policy, smart-indent triggers).
- **Formatting (future)**
  - Provide formatter integration as an optional capability.
  - Must be explicit + deterministic (format-on-save is opt-in).
- **Symbol extraction / outline (index-backed when available)**
  - Provide a way to extract symbols for outline and search.
  - Must support fallback behavior when deep parsing is unavailable.
- **Navigation + refactors (future)**
  - Go-to-definition, references, rename.
  - Prefer LSP when configured; fallback to index heuristics where possible.
- **Linting / diagnostics (future)**
  - Provide lint + diagnostics integration (LSP, external tool, or internal rules).
  - Output must map to file/line and feed the Problems/Diagnostics surfaces.
- **Scaffolding (future)**
  - Provide scaffold by creating language/framework specific files, folders, and structures (supported by right click menu).

### Architectural implications

- The index, navigation, and search layers should treat “language support” as an injected dependency (providers/modules), not a special-case branch.
- Any “fallback” parsing must be explicitly positioned as:
  - best-effort
  - language-module-owned
  - replaceable when a more robust capability implementation is added.

### Current foundation (already in-progress)

- Language modules + enable/disable list
- Syntax highlighting pipeline
- CodebaseIndex symbol tables and indexed search surfaces with graceful fallback

### Out of scope (for now)

- A full Language Server implementation per language (we integrate with LSP; we don’t build an LSP).
- Shipping a vendor SDK/parser as a core dependency requirement.

## File browser

- [x] File menu: new file / new project
  - **Primary surface**: File menu + Command palette.
  - **Command IDs**: `file.new`, `project.new`.
  - **Purpose**: start a new buffer or create a new project workspace.
- [x] File menu: open file / open folder
  - **Primary surface**: File menu.
  - **Command IDs**: `file.open`, `file.openFolder`.
  - **Purpose**: open a file or choose a workspace root.
- [x] File menu: save / save as
  - **Primary surface**: File menu.
  - **Command IDs**: `file.save`, `file.saveAs`.
  - **Purpose**: persist editor buffers to disk deterministically.
- [x] Create file / folder (context menu + dialog)
  - **Acceptance**: right-clicking a folder creates inside that folder; right-clicking a file creates in its parent; right-clicking empty tree area creates at project root.
- [x] Search by name
- [x] Show hidden files toggle (Cmd+Shift+.)
- [x] Open file (double click)
- [x] Open file (right click menu)
  - **Primary surface**: file tree item context menu.
  - **Command IDs**: `explorer.openSelection` (default action).
  - **Behavior**: for files, open in editor; for folders, toggle expand/collapse; when search is active, opening a result keeps search state unchanged.
  - **Acceptance**: context menu “Open” works for both normal tree + search results and matches double-click behavior.
- [x] Delete (file/folder via context menu, toolbar, Cmd+Delete)
  - **Primary surface**: file tree context menu + Edit/File menu.
  - **Command IDs**: `explorer.deleteSelection` (Cmd+Delete).
  - **Behavior**: move to Trash by default; confirm for non-empty folders; block deletes outside project root; refresh tree and selection deterministically.
  - **Acceptance**: deleted items disappear immediately; deleting an open file closes its editor tab (prompt if dirty).
- [x] Rename (file/folder via context menu, toolbar, keyboard)
  - **Primary surface**: in-place rename in file tree (recommended) + context menu.
  - **Command IDs**: `explorer.renameSelection` (F2).
  - **Behavior**: validate name; preserve extension by default (optional toggle); prevent collisions; update any open tabs that point to the renamed path.
  - **Acceptance**: rename updates disk + tree + any open editor state without “ghost” paths.
- [ ] Open file (tabbed by default once Tabs ship)
  - **Dependencies**: editor tabs.
  - **Behavior**: opening a file focuses an existing tab (no duplicates); otherwise creates a new tab.
  - **Keybindings**: keep `Cmd+O` / `Cmd+Shift+O` reserved for external file/folder open dialogs.
- [x] Show in Finder (context menu, Cmd+Shift+F)
  - **Command IDs**: `explorer.revealInFinder` (Cmd+Shift+F).
  - **Behavior**: reveal selected file/folder using `NSWorkspace.shared.activateFileViewerSelecting([url])`.
  - **Acceptance**: Finder opens with the exact selection highlighted.
- [ ] Drag & drop move/copy (incl. between folders)
  - **Primary surface**: file tree drag-and-drop.
  - **Behavior**: move on drop by default; hold Option to copy; show insertion highlight; forbid drops outside project root; refresh tree + keep expanded state stable.
  - **Acceptance**: move/copy works reliably for files and folders and updates git decorations/watchers.
- [ ] File-system watcher (auto-refresh on disk changes)
  - **Goal**: the tree reflects edits made outside the app (git checkout, CLI edits, file generators).
  - **Behavior**: observe project root via FSEvents (preferred) with debounce; invalidate caches and reload tree without collapsing expanded folders.
  - **Acceptance**: creating/deleting/renaming files on disk updates the tree within ~250ms without manual refresh.
- [ ] Git decorations (M/A/D/ignored/untracked)
  - **Primary surface**: file tree row badges + subtle tinting.
  - **Behavior**: derive from `git status --porcelain=v1` (or libgit2 later); cache results; update on watcher events + after agent applies patches.
  - **Acceptance**: decorations match `git status` for common states and never block UI.

## Code viewer
- [x] Tabs (no duplicates, close per tab, icon/name/close affordances, context menu)
  - **Primary surface**: tab strip in the editor header.
  - **Command IDs**: `editor.tabs.closeActive` (Cmd+W), `editor.tabs.closeAll`, `editor.tabs.next` (Ctrl+Tab), `editor.tabs.previous` (Ctrl+Shift+Tab).
  - **State**: each tab owns `{fileURL, isDirty, cursor/selection, scroll position}`.
  - **Behavior**: opening a file focuses existing tab (no duplicates); closing dirty tab prompts; tab title shows dirty dot.
  - **Persistence**: store open tabs + active tab in `.ide/session.json` (ProjectSession).
  - **Acceptance**: can open/close/switch tabs without losing editor state; no duplicate tabs for same file.
- [x] Format document
  - **Primary surface**: editor.
  - **Command IDs**: `editor.format`.
  - **Behavior**: format the current buffer using the active language module when available, otherwise fall back to the built-in formatter.
  - **Acceptance**: formatting is deterministic and does not lose selection/cursor.
- [x] Split editor (vertical/horizontal) + tab groups
  - **Primary surface**: editor layout controls + drag tab to edge to split.
  - **Command IDs**: `editor.splitRight` (Cmd+\), `editor.splitDown`, `editor.focusNextGroup`.
  - **Behavior**: each split is a tab group; “open file” targets the focused group; closing last tab collapses group.
  - **Acceptance**: can split editor and open different files in each group.
- [x] Find in file (Cmd+F)
  - **Primary surface**: search/replace bar in the editor.
  - **Behavior**: find next/previous; highlight; replace.
  - **Acceptance**: works in large files, doesn’t hang UI.
  - **Acceptance**: find/replace works with large files and preserves selection/scroll.
- [x] Global search (Cmd+Shift+F) with preview results
  - **Primary surface**: left “Search” panel or modal panel with results list + preview.
  - **Command IDs**: `search.findInWorkspace` (Cmd+Shift+F).
  - **Behavior**: search across project; results grouped by file; click jumps to line; support replace-in-files with preview and per-file selection.
  - **Implementation note**: use CodebaseIndex when enabled; fallback to ripgrep-style scan with cancellation.
  - **Acceptance**: search is cancelable, returns line numbers, and opens the correct file/line reliably.
- [x] Quick Open (Cmd+P) + fuzzy file search (use CodebaseIndex when available)
  - **Primary surface**: Quick Open overlay.
  - **Command IDs**: `workbench.quickOpen` (Cmd+P).
  - **Behavior**: fuzzy match file names/paths; supports `path:line` suffix; shows recent + pinned; Enter opens, Cmd+Enter opens to side (split).
  - **Acceptance**: opens correct file instantly on large repos; never blocks UI.
- [x] Command palette (Cmd+Shift+P) wired to `CommandRegistry`
  - **Primary surface**: command palette overlay (search + list).
  - **Command IDs**: `workbench.commandPalette` (Cmd+Shift+P).
  - **Behavior**: shows all registered commands with optional keybinding hints; fuzzy search; runs selected command; supports “>” prefix (optional) for command-only.
  - **Acceptance**: any implemented feature is discoverable and runnable from the palette (no dead commands).
- [x] Symbol navigation: outline pane, “Go to Symbol…” (Cmd+T)
  - **Primary surface**: outline sidebar for current file + quick symbol picker.
  - **Command IDs**: `workbench.goToSymbol` (Cmd+T).
  - **Behavior**: show symbols for current file; search symbols; selecting navigates to definition line.
  - **Implementation note**: use CodebaseIndex symbol tables where available; fall back to lightweight parsing.
  - **Acceptance**: symbol picker navigates accurately and is fast for Swift/JS/TS/Python.
- [x] Go to definition / find references / rename symbol (LSP-backed; fallback to index heuristics)
  - **Primary surface**: editor context menu + shortcuts.
  - **Command IDs**: `editor.goToDefinition`, `editor.findReferences`, `editor.renameSymbol`.
  - **Behavior**: when LSP is configured, use it; otherwise provide best-effort via index; if neither is available, show a clear “not available” message (no silent failure).
  - **Acceptance**: never navigates to the wrong file silently; ambiguous results must present a picker.
- [x] Diagnostics surface + clickable build errors (terminal ↔ editor)
  - **Primary surface**: problems list + inline squiggles (later) + terminal links.
  - **Command IDs**: `view.toggleProblems`, `problems.next`, `problems.previous`.
  - **Behavior**: parse build/test output (start with Swift/Xcodebuild) into file:line diagnostics; clicking jumps to location.
  - **Acceptance**: running build/tests produces actionable, clickable errors; diagnostics persist until next run.
- [x] Code folding
  - **Primary surface**: editor.
  - **Command IDs**: `editor.toggleFold`, `editor.unfoldAll`.
  - **Behavior**: fold/unfold at cursor; unfold all.
  - **Acceptance**: folding is fast and does not corrupt selections.
- [x] Minimap
  - **Primary surface**: editor.
  - **Command IDs**: `view.toggleMinimap`.
  - **Behavior**: toggle minimap visibility.
  - **Acceptance**: minimap toggle works and does not regress editor performance.
- [x] Multi-cursor
  - **Primary surface**: editor.
  - **Command IDs**: `editor.addNextOccurrence`, `editor.addCursorAbove`, `editor.addCursorBelow`.
  - **Behavior**: add next occurrence; add cursor above/below.
  - **Acceptance**: multi-cursor operations are predictable and consistent.
- [x] Status bar language indicator + override picker (VS Code-style)
  - **Primary surface**: bottom status bar.
  - **Purpose**: display the currently effective language mode for the active editor file, and allow overriding incorrect detection (e.g. `js` vs `jsx`, `ts` vs `tsx`).
  - **Behavior**
    - Shows a language label (e.g. “Swift”, “TypeScript React”) only when a real file is open in the editor.
    - Clicking the label opens a picker with “Auto Detect” plus a curated list of common languages.
    - Selecting a language forces the editor/highlighter to treat the active file as that language.
    - Selecting “Auto Detect” clears the override.
  - **Persistence**: per-project, stored under `.ide/session.json` as `languageOverridesByRelativePath`.
  - **Acceptance**
    - When no file is open (untitled buffer), the language indicator is not shown.
    - Changing the selection immediately updates syntax highlighting.
    - Overrides survive app restart and re-open of the same project.
- [ ] Block (rectangular) selection
  - **Primary surface**: editor.
  - **Acceptance**: rectangular selection works without breaking normal selection behavior.

## Settings & preferences
- [x] Settings UI (General + AI)
  - **Primary surface**: Settings window.
  - **Purpose**: single place to configure global UI preferences and AI provider settings.
- [x] Editor preferences (font size, font family, indentation style)
  - **Primary surface**: Settings → General.
  - **Purpose**: persist editor UX preferences (font + indentation).
- [x] AI provider settings (OpenRouter)
  - **Primary surface**: Settings → AI.
  - **Purpose**: configure API key, model, base URL, and reasoning toggle.

## Terminal
- [x] Native terminal panel
  - **Primary surface**: bottom panel.
  - **Purpose**: run build/test commands and view output inside the IDE.
- [x] Inline AI assist (send current selection/buffer to AI)
  - **Primary surface**: editor + AI panel.
  - **Command IDs**: `editor.aiInlineAssist`.
  - **Behavior**: opens the AI panel (if hidden) and sends the current selection if present; otherwise sends the current buffer.
  - **Acceptance**: always makes the scope explicit (selection vs buffer) and never silently writes to disk.
- [ ] Syntax-aware AI support (Cmd+I) for analyze/fix/enrich current buffer
  - **Primary surface**: editor action + AI panel.
  - **Command IDs**: `ai.analyzeFile` (Cmd+I).
  - **Behavior**: sends current file (and optional selection) as context; returns either (a) explanation/suggestions or (b) a proposed patch set (see Milestone 3).
  - **Acceptance**: AI never edits disk directly; it proposes changes with preview unless “Auto-apply” is explicitly enabled.
- [ ] Inline AI chat (Cmd+Shift+I) scoped to current file/selection
  - **Primary surface**: inline popover anchored to cursor/selection.
  - **Command IDs**: `ai.inlineChat` (Cmd+Shift+I).
  - **Behavior**: conversation scoped to the current file; can propose edits only within that file by default; “expand scope” requires explicit user action.
  - **Acceptance**: inline chat does not pollute global conversation unless user chooses to promote it.
- [ ] Inline code actions (cursor/selection): explain, refactor, tests, fix diagnostics
  - **Primary surface**: context menu + lightbulb affordance (optional) + shortcut.
  - **Command IDs**: `ai.codeActions` (Cmd+.).
  - **Behavior**: actions are deterministic presets (Explain / Refactor / Generate tests / Fix diagnostics) with predictable context.
  - **Acceptance**: each action clearly states scope (selection/file/project) and produces either a response or a proposed patch set.
- [ ] Diff-first apply flow for AI edits (per-hunk accept/reject, rollback)
  - **Primary surface**: AI “Proposed Changes” + Diff viewer.
  - **See**: Milestone 3 (Diff-first) + Milestone 4 (Checkpoints).

## AI Agent & autonomy

### Agent workflow architecture (spec)

We treat the “agent” as a deterministic workflow composed of specialized roles.

#### Goals

- **Autonomy with control**: plan → propose → review → apply → verify → summarize.
- **Deterministic behavior**: stable tool ordering and reproducible outcomes.
- **Reversibility**: every write is undoable (git or checkpoints).
- **Context correctness**: prefer local index; never guess paths.

#### Non-negotiable rules

- **Command-first**: user-facing actions map to `CommandID`.
- **Explicit scope**: selection/file/project scope is stated before acting.
- **No guessed paths**: discover via index tools (`index_find_files`, `index_list_files`) before reading/writing.
- **Prefer propose-first**: generate patch sets before applying writes (Milestone 3).
- **Loop protection**: all self-iterations are capped; final status must be explicit.

### Multi-role agent model

The agent pipeline is split into roles for SRP and quality.

- **Architect (high-level strategy)**
  - **Responsibility**: establish project outline, constraints, and milestones.
  - **Outputs**
    - strategy summary (assumptions, tradeoffs, risks)
    - milestone roadmap with acceptance criteria
    - verification plan (commands + expected results)
  - **Tool policy**: read-only tools only.
  - **Current code hook**: `ArchitectAdvisorTool` (already exists) for focused architecture guidance.

- **Planner (persistent plan manager)**
  - **Responsibility**: maintain a durable execution plan across tool loops and long sessions.
  - **Tool**: `PlannerTool` (already exists) → `ConversationPlanStore`.
  - **Plan format (markdown)**
    - milestones
    - per-milestone steps
    - current step marker
    - explicit stop condition

- **Worker (tool-using executor)**
  - **Responsibility**: execute concrete steps using tools; keep actions minimal and reversible.
  - **Tool policy**: allowed tools depend on `AIMode` + safety settings.
  - **Operating rules**
    - prefer index summaries/memories before reading full files
    - do discovery first, then narrow reads, then propose edits
    - update plan progress after each tool batch

- **QA / Code Review agent (quality gate)**
  - **Responsibility**: review proposed changes vs plan/spec and quality bar.
  - **Outputs**: sign-off OR actionable review feedback.
  - **Tool policy**: read-only tools + diff view.
  - **Iteration cap**: max 3. On iteration 3, reviewer must explicitly mark “last chance” and list must-fix items.

- **Finalizer (user-facing closure)**
  - **Responsibility**: final summary that is consistent with what was executed.
  - **Outputs**
    - objective restatement
    - touched files
    - verify status + how to re-run
    - how to undo (checkpoint/git)
  - **Tool policy**: no tools.

### Execution lifecycle (state machine)

Each agent run is modeled as a state machine with a stable `runId`.

- **States**
  - `Intake` → validate request, scope, constraints
  - `ContextPack` → gather index summaries/memories + minimal reads
  - `Strategy` → Architect produces roadmap + acceptance criteria
  - `PlanPersist` → Planner persists plan
  - `Execute` → Worker runs tool batches
  - `Propose` → create patch set (diff-first)
  - `Review` → QA review (loop cap 3)
  - `Apply` → apply patch set (checkpoint first)
  - `Verify` → run allowlisted commands (loop cap 2–3)
  - `Finalize` → consistent summary and next steps

### Indexing & context intelligence integration

The agent must prefer CodebaseIndex for discovery and context selection.

- **Context routing order**
  - (1) user-pinned context
  - (2) index summaries/memories
  - (3) index file/symbol search
  - (4) direct file reads
  - (5) filesystem scan fallback

- **AI enrichment (already implemented)**
  - per-file summaries + quality scores in `CodebaseIndex.runAIEnrichment()`.
  - used by Architect/Planner to understand the system quickly.
  - used by Worker to avoid low-signal exploration.

### Context condensation (folded conversation history)

To protect the model context window, older conversation history can be condensed and moved out of the active prompt.

- **Storage**: folded content is stored under `.ide/chat/folds/`.
  - `index.json`: list of folds (id, summary, createdAt)
  - `<id>.txt`: the folded transcript content

- **Automatic folding**: `ConversationManager` may fold the oldest messages when thresholds are exceeded.

- **Rehydration**: the agent can rehydrate folded context via the `conversation_fold` tool.
  - `action=list` to see available folds and their summaries
  - `action=read` with an `id` to retrieve the full folded content

### Safety policies (must be enforceable)

- **Role-based tool access**
  - Architect/QA: read-only tools.
  - Worker: write/run tools gated by settings, path validation, and (preferably) propose-first workflow.

- **Command safety**
  - verify commands are allowlisted per project.
  - destructive commands require explicit confirmation.

- **Write safety**
  - validate all paths are within project root.
  - serialize writes per-path (Milestone 2).

### Loop protection

- **Tool loop cap**
  - agent tool-call loop is capped (already present in `ConversationManager`).

- **Review loop cap**
  - max 3 review iterations.

- **Verify loop cap**
  - max 2–3 verify retries.

### Current implementation (as-is)

- `ConversationManager` orchestrates model → tools → model with a tool-loop cap.
- `AIToolExecutor` executes tool calls sequentially and logs progress.
- `PlannerTool` persists plan markdown.
- `ArchitectAdvisorTool` provides architecture guidance with index context.
- `CodebaseIndex` supports file/symbol search + AI enrichment + quality scoring.

### Implementation roadmap (agent-specific)

- **Role separation**: introduce role prompts + persist Strategy/Review artifacts under `.ide/`.
- **Diff-first + checkpoints**: implement PatchSetStore/DiffViewer (Milestone 3) + CheckpointManager (Milestone 4).
- **QA loop + verify loop**: add capped review iterations and allowlisted verify retries.
- **Tool lanes**: introduce safe parallelism for reads + serialized writes (Milestone 2).

## Project tracker — Agent ecosystem (implementation plan)

This tracker is the authoritative execution plan for building the full agent ecosystem described above.

### Global engineering requirements (apply to every milestone)

- **Observability**
  - Every agent run has a stable `runId`.
  - Every tool call has a stable `toolCallId`.
  - Logs must be structured (key/value) and persist to `.ide/logs/`.
  - UI must expose an execution timeline (inputs → tool calls → outputs → errors).

- **Error handling + recovery**
  - Errors are actionable (what failed, why, what the user can do next).
  - Cancellation must be respected end-to-end.
  - On app restart, in-flight runs are marked as interrupted and can be inspected.
  - Writes must be reversible (git or checkpoints).

- **Determinism + safety**
  - Tool ordering is stable.
  - Writes are serialized per-path.
  - Destructive operations are gated.
  - Path validation is enforced for all file tools.

- **Testing**
  - Each milestone must add/extend unit tests.
  - UI tests are tracked as Phase 2 stories (can be implemented later).

### Milestone A — Execution engine + traceability UI (foundation)

**Outcome**: deterministic tool execution with trace IDs and a UI that clearly shows executed tools/commands and results.

#### User stories (Milestone A)

- **Story A1 — Tool execution timeline**
  - As a user, I can see every tool call executed for my request, its status, and its output.
  - **Acceptance**
    - Timeline shows: tool name, target file/command, start time, end time, duration, status, and output preview.
    - Selecting an entry shows full output and any structured metadata.

- **Story A2 — Deterministic scheduler**
  - As a user, tool calls execute deterministically and UI never “reorders” history.
  - **Acceptance**
    - Tool calls have stable indices and UI reflects them in order.
    - Parallel reads/search/index are supported; writes are serialized per-path.

- **Story A3 — Cancellation and partial progress**
  - As a user, I can cancel a running tool batch and see what completed and what was cancelled.
  - **Acceptance**
    - Cancel stops pending work quickly.
    - Completed tool outputs remain visible.
    - Cancelled entries are clearly marked.

#### Engineering scope

- **Scheduler**
  - Introduce `ToolScheduler` (actor) with:
    - bounded concurrency for read-only tools
    - per-path locks for write tools
    - deterministic emission of progress events (stable ordering)

- **Logging + traceability**
  - Standardize on `runId` + `toolCallId` propagation across:
    - `ConversationManager`
    - `AIToolExecutor`
    - `ExecutionLogStore` / `ConversationLogStore`
  - Ensure tool progress streaming events are persisted for debugging.

- **UI**
  - Add a dedicated “Tasks / Execution” surface in the AI panel:
    - timeline list
    - details inspector
    - copy/export output

#### Unit tests (Milestone A)

- `ToolScheduler` does not run two write tasks concurrently for the same path.
- Parallel read tasks respect max concurrency and produce deterministic ordering.
- Cancel stops queued tasks and marks them cancelled.

#### Phase 2 UI tests backlog (Milestone A)

- Verify tool timeline renders start→progress→complete.
- Verify cancel button marks tasks cancelled.
- Verify selecting a timeline row shows full output.

### Milestone B — Diff-first patch sets + checkpoints (trust + reversibility)

**Outcome**: agent proposes patch sets; user reviews; apply is checkpointed and reversible.

#### User stories (Milestone B)

- **Story B1 — Propose multi-file patch set**
  - As a user, the agent proposes changes as a patch set instead of writing directly.

- **Story B2 — Review + apply**
  - As a user, I can review a patch set and apply it safely.

- **Story B3 — Rollback**
  - As a user, I can restore the previous state via checkpoint.

#### Unit tests (Milestone B)

- Patch set manifest roundtrip.
- Apply writes expected bytes.
- Checkpoint restore restores exact bytes.

#### Phase 2 UI tests backlog (Milestone B)

- Per-file accept/reject.
- Restore checkpoint confirmation flow.

### Milestone C — Multi-role orchestration (Architect → Worker → QA → Finalizer)

**Outcome**: role-separated runs with review loop (max 3) and verify loop (allowlisted, capped).

#### User stories (Milestone C)

- **Story C1 — Strategy + plan persisted**
  - As a user, I get a clear strategy and milestone plan saved to the plan store.

- **Story C2 — QA review loop**
  - As a user, I see review feedback; the system caps to 3 iterations and clearly communicates the final attempt.

- **Story C3 — Verify loop**
  - As a user, the agent runs allowlisted verify commands, retries failures up to the cap, then stops with a clear status.

#### Unit tests (Milestone C)

- Review loop stops at 3 and marks last iteration.
- Verify loop retries up to cap and surfaces final status.

#### Phase 2 UI tests backlog (Milestone C)

- Verify “Review required” state blocks apply.
- Verify “Verify failed” state shows command output and next actions.

### Milestone D — Index-powered context engine + debt payoff workflows

**Outcome**: systematic context selection and optional refactor/debt payoff mode driven by index summaries and quality scores.

#### User stories (Milestone D)

- **Story D1 — Context pack transparency**
  - As a user, I can see which context sources were used (summaries, files, symbols).

- **Story D2 — Debt payoff plan**
  - As a user, I can request “pay down debt” and the agent generates a safe, reversible plan with verification.

#### Unit tests (Milestone D)

- Context packing respects budget and is deterministic.

#### Phase 2 UI tests backlog (Milestone D)

- Context list/pin/unpin flow.

### Definition of Done (every milestone)

- Feature works end-to-end.
- Structured logs are emitted with `runId` and `toolCallId`.
- Errors are actionable and recoverable.
- Unit tests added/updated and passing.
- Tracker updated if scope changed.

- [ ] Git integration: agent ends each request with a commit + summary (toggleable)
  - **Primary surface**: AI panel “Review” step + Command palette.
  - **Command IDs**: `git.commitFromAgent`, `git.showStatus`, `git.showDiff` (names are placeholders; must map to real `CommandID`s).
  - **Behavior**: If an agent run changed files and user approves apply, show a “Ready to commit” card: changed file list + short diff summary + suggested commit message.
  - **Acceptance**: after a successful agent run, user can create a single atomic commit (or skip) without leaving the IDE.
- [ ] Conversation tabs/history UI: browse, resume, delete history files
  - **Primary surface**: AI panel top bar (tabs) + history drawer.
  - **Persistence**: store per-conversation messages under `.ide/chat/<conversationId>.json` (or evolve from current `history.json`) and list conversations from `.ide/logs/conversations/index.ndjson`.
  - **Behavior**: create new conversation, switch, resume, delete (deletes files + logs for that conversation).
  - **Acceptance**: closing/reopening the project restores conversation list and the last active conversation.
- [ ] Plan UI: pinned plan view + live progress (tool calls ↔ checklist)
  - **Primary surface**: AI panel “Plan” tab (pinnable) + compact progress in status bar.
  - **Data source**: `PlannerTool` ↔ `ConversationPlanStore` plus tool-call stream from `ConversationManager`.
  - **Behavior**: render plan markdown; highlight current step; tool executions update step state; allow user to edit/clear plan manually.
  - **Acceptance**: plan state survives app restart and stays consistent with executed tool calls.
- [x] Planner tool (persistent plan storage)
- [x] Markdown rendering for chat
- [x] Project-scoped chat history persistence
  - **Primary surface**: AI panel.
  - **Persistence**: `.ide/chat/history.json`.
  - **Purpose**: preserve conversation across app restarts per project.
- [ ] Streaming responses (SSE) + live tool execution streaming
  - **Primary surface**: AI message list (typing should be actual stream, not spinner).
  - **Behavior**: stream tokens into the last assistant message; stream tool call start/complete events as they happen.
  - **Implementation map**: extend `OpenRouterAIService` + `OpenRouterAPIClient` to support SSE when available; update `ConversationManager` to append partial assistant content without creating extra messages.
  - **Acceptance**: long responses render progressively; cancelling stops streaming quickly.

## Project session & layout persistence
- [x] Project session persistence (window/layout/open tabs)
  - **Primary surface**: whole app.
  - **Persistence**: `.ide/session.json`.
  - **Purpose**: restore window frame, sidebar/terminal/AI visibility, split state, open tabs, and file tree expansion state.
- [ ] Agent verify loop: run tests/build/linters; iterate until green with loop protection
  - **Primary surface**: AI panel “Verify” step + Task lanes (Milestone 2).
  - **Behavior**: after apply, run configured commands (default: `./run.sh test`); if failing, feed concise failure into the agent, propose fix, and retry with a hard cap (e.g., 2–3).
  - **Safety**: verify commands are allowlisted per project; agent can’t add new verify commands without user approval.
  - **Acceptance**: when enabled, the agent stops only on success or cap and produces a final short summary.
- [ ] AI self-review + auto-fix pass before final reply
  - **Behavior**: before responding “done”, the agent must: (1) restate objective, (2) list touched files, (3) confirm verify status, (4) flag any remaining risks/todos.
  - **Acceptance**: no “done” responses without an explicit review block (brief, consistent).
- [ ] Project “rules & memory” UI (repo-specific guardrails for the agent)
  - **Primary surface**: Settings → AI + optional pinned “Rules” panel.
  - **Persistence**: `.ide/agent/rules.md` + `.ide/agent/memory.json` (or reuse Index memory storage).
  - **Behavior**: rules are injected into system prompt every request; memory can be appended by explicit user action (“Save as project memory”).
  - **Acceptance**: user can inspect exactly what rules/memory the agent is using for this repo.
- [ ] Local/on-device model support (Apple Silicon optimized) + per-task routing (fast vs deep)
  - **Goal**: latency + privacy wins for lightweight tasks (summaries, embeddings, intent classification).
  - **Design**: provider abstraction in `AIService` (remote + local) with routing rules (per command/action).
  - **Acceptance**: user can choose “local-first for summaries/search” without breaking core chat/agent flows.
- [ ] Safety rails: destructive command gating, path allowlist UI, dry-run mode
  - **Behavior**
    - Extend `PathValidator` rules to cover more operations (rename/move, glob patterns).
    - Gate destructive shell commands (`rm`, `git reset --hard`, etc.) behind explicit confirmation and/or an allowlist.
    - “Dry-run” mode runs tools that only read; write tools produce a proposed patch set only.
  - **Acceptance**: agent cannot destroy data silently; the user always sees what will change before it changes.
- [ ] Diff-aware apply: preview multi-file patch, per-file/hunk accept/reject, one-click rollback
  - **See**: Milestone 3 (Diff-first) + Milestone 4 (Checkpoints).
- [ ] Inline execution controls: cancel, pause, step, rerun last tool set
  - **Primary surface**: AI panel toolbar + Task lanes.
  - **Behavior**: cancel stops current tool + prevents queued tools; pause stops after current tool; step runs exactly one tool call batch; rerun repeats last batch (with confirmation if it writes).
  - **Acceptance**: users can safely interrupt and resume agent runs without corrupting state.
- [ ] Multi-modal context: screenshots/attachments -> text context for the agent
  - **Primary surface**: AI input supports drag/drop/paste of images/files.
  - **Persistence**: store attachments under `.ide/attachments/` with references from conversation JSON.
  - **Behavior**: images are summarized locally (preferred) or sent to model if supported; attachments can be referenced (“use screenshot 3”).
  - **Acceptance**: attachments are project-scoped, deletable, and never silently uploaded without user control.

## Indexing & context intelligence
- [x] CodebaseIndex core (local index for files, symbols, and retrieval)
  - **Primary surface**: internal service used by Quick Open, Go to Symbol, and Search.
  - **Purpose**: enable fast file/text/symbol lookup on large projects with graceful fallback when disabled.
  - **Acceptance**: enabling/disabling index never breaks core features; it only changes performance/quality.
- [ ] CodebaseIndex UX: file/symbol search surfaces in Quick Open/outline
  - **Primary surface**: Quick Open, Symbol picker, Search panel.
  - **Behavior**: if CodebaseIndex is enabled, queries should use it by default; if disabled/unavailable, fall back to filesystem scan.
  - **Acceptance**: Quick Open and Symbol picker remain fast on large repos and don’t depend on network.
- [ ] Context windows: automatic selection propagation (done), add “send buffer” and “send file” buttons
  - **Primary surface**: AI panel context header.
  - **Behavior**: one-click “Add selection”, “Add current file”, “Add open tabs”, with a visible context list and a clear “remove” action.
  - **Acceptance**: user can see exactly what context will be sent before pressing Send.
- [ ] Summaries/memories surfaced in chat (per file or folder)
  - **Behavior**: show “Index Summary” chips (file/folder) that can be inserted into chat context; allow pin/unpin.
  - **Acceptance**: summaries are cached, quick to load, and clearly marked as generated artifacts.
- [ ] Semantic search over docs/code (streamed results)
  - **Behavior**: semantic query returns ranked file/snippet hits; show top N with preview; allow “Add to context”.
  - **Acceptance**: search is cancelable and deterministic (same query → same ordering with same index).
- [ ] Knowledge routing: prefer cached summaries; fall back to live reads only when needed
  - **Rule**: always try: (1) pinned context, (2) cached summaries/memories, (3) index reads, (4) direct file reads; never “guess” file names.
  - **Acceptance**: agent prompts show consistent context selection and fewer irrelevant reads.

## Collaboration & presence
- [ ] Live cursor presence + follow mode (future multi-user)
  - **Scope**: future; only after core editor tabs/splits and a stable document model exist.
  - **Acceptance (when started)**: presence is opt-in, project-scoped, and never impacts editor latency.
- [ ] Shareable AI session transcript export (Markdown/HTML)
  - **Primary surface**: AI panel menu + Command palette.
  - **Command IDs**: `ai.exportTranscriptMarkdown`, `ai.exportTranscriptHTML`.
  - **Behavior**: export a single conversation with tool calls and timestamps; allow redacting secrets; output to a user-chosen path.
  - **Acceptance**: exported transcript is readable outside the IDE and preserves code blocks/diffs.
- [ ] Commenting on files (inline notes stored under .ide)
  - **Primary surface**: editor gutter + context menu.
  - **Persistence**: `.ide/notes/comments.json` keyed by `{filePath, line, id}`.
  - **Behavior**: add/edit/resolve comments; show comment indicators; searchable via Command palette.
  - **Acceptance**: comments survive restart and don’t modify source files.

## Performance & UX polish
- [ ] Low-latency streaming UI with partial rendering for large outputs
  - **Rule**: rendering must be incremental and bounded (no quadratic re-layout).
  - **Acceptance**: streaming a 2k-token response stays smooth; scrolling remains responsive.
- [ ] Background pre-warm of models/tools based on intent
  - **Behavior**: pre-warm index queries and AI service handshake after project open; do not auto-send user data.
  - **Acceptance**: first AI request latency decreases without breaking offline mode.
- [ ] Offline-first behaviors with graceful degradation
  - **Behavior**: if AI is unavailable, IDE still functions fully; show clear “offline” states; queue optional actions.
  - **Acceptance**: no feature hard-crashes when network is down; errors are actionable.

## Native macOS differentiators (why we win vs Chromium IDEs)
- [ ] Quick Look everywhere: Space preview in file tree, search results, git changes, Quick Open
  - **See**: Milestone 1. Key command: `view.quickLook` (Space).
- [ ] Pinned Inspector/Preview panel: metadata, labels/tags, thumbnails, Quick Look, “Ask Agent about this”
  - **See**: Milestone 1. Key command: `panel.toggleInspector`.
- [ ] APFS-backed checkpoints: instant snapshot + per-file rollback (agent runs + manual)
  - **See**: Milestone 4. Key commands: `checkpoint.create`, `checkpoint.restore`.
- [ ] Transactional agent runs: plan → diff → apply → verify → (optional) commit; always reversible
  - **Primary surface**: AI panel run summary + Task lanes.
  - **Rule**: any run that would write must produce (or reference) a patch set; apply is explicit and reversible via checkpoint or git.
  - **Acceptance**: users can always answer “what changed, why, and how do I undo it?” from the UI.
- [ ] Tool “lanes” + safe parallelism: parallel reads/search/index; serialized writes with path locks; cancel/pause/step
  - **See**: Milestone 2.
- [ ] On-device context intelligence: semantic index + “best context pack” selection (fast local compute, remote LLM optional)
  - **See**: Milestone 5.
- [ ] System automation hooks: Shortcuts/App Intents + Services menu + global hotkeys (CommandRegistry-backed)
  - **Primary surface**: macOS Services, Shortcuts, menu items.
  - **Behavior**: expose a small set of safe, stable commands as App Intents (open project, run tests, ask AI with selected text, create checkpoint).
  - **Acceptance**: user can automate common workflows without scripting and without granting broad permissions.
- [ ] First-class privacy: per-project secrets in Keychain, audit log of tool actions, data residency controls
  - **Persistence**: secrets stored in Keychain scoped by project identifier; audit logs under `.ide/logs/`.
  - **Behavior**: every tool call and write action is logged with timestamps + paths; UI offers “View audit log” and “Redact & export”.
  - **Acceptance**: users can prove what the agent did and control what leaves the machine.

## Milestones (top 5, 2–3 weeks each)

### Milestone 1 — Quick Look + Inspector preview (delight + speed)
- **Goal**: instant “Space to preview” for any file, plus a pinned Inspector for browsing.
- **Primary surface**: File Tree + Right Panel.
- **Command IDs**
  - `view.quickLook`: Space (File Tree focused) toggles transient preview.
  - `panel.toggleInspector`: shows/hides pinned Inspector panel.
- **Dependencies**
  - File selection in tree must be stable (already: `selectedRelativePath`).
  - Right panel must support multiple tabs/panels (AI + Inspector) without “dead” toggles.
- **Implementation map**
  - `Compass/Components/ModernFileTreeView.swift`: capture Space when outline view is first responder; resolve selected file URL.
  - `Compass/Components/FileExplorerView.swift`: forward selection + focused state if needed.
  - `Compass/ContentView.swift`: replace “single right panel view” with a container that can show AI and Inspector.
  - New: `Compass/Components/QuickLookPreviewView.swift` (NSViewRepresentable wrapping `QuickLookUI` preview view).
  - New: `Compass/Services/QuickLookService.swift` (shared controller + selection binding).
- **Acceptance criteria**
  - Space on a file shows a Quick Look preview; Space again or Esc closes.
  - Preview never opens for directories.
  - Pinned Inspector can show the same preview without stealing File Tree focus.
  - “Ask Agent about this file” injects file path into chat context (no guessing paths).
- **Out of scope**
  - Custom rendering for every file type (use system Quick Look).
  - Voice readout.
- **Test plan**
  - Manual: preview text file, image, PDF; verify Esc closes; verify directory no-op.

### Milestone 2 — Tool lanes + safe parallel execution (native performance)
- **Goal**: UI stays responsive while the agent/index/search run concurrently, with safe cancellation.
- **Primary surface**: Right panel (Agent) + Status bar + “Tasks” popover.
- **Core rule set (non-negotiable)**
  - Read/search/index may run concurrently.
  - Writes are serialized per absolute path (no two write tools can touch same path in parallel).
  - Shell commands default to single-flight unless explicitly marked safe-to-parallel.
  - UI progress order must be deterministic (stable ordering by tool-call index).
- **Implementation map**
  - `Compass/Services/AIToolExecutor.swift`: introduce a scheduler (actor) that can run safe tool calls concurrently with per-path locks and a max concurrency limit.
  - `Compass/Services/ConversationManager.swift`: propagate cancellations; surface tool lanes/progress events.
  - New: `Compass/Services/ToolScheduler.swift`, `Compass/Services/AsyncLockMap.swift`.
  - New UI: `Compass/Components/TaskLanesView.swift` + status bar affordance.
- **Acceptance criteria**
  - Multiple read/index tools can run in parallel without UI freezes.
  - Two write tools targeting same file are never concurrent.
  - Cancel stops pending work quickly and leaves UI in a consistent state.
- **Out of scope**
  - Parallelizing “apply patch” within the same file.
- **Test plan**
  - Unit: lock map prevents concurrent writes to same path.
  - Manual: trigger multiple tool calls; verify progress + cancel behavior.

### Milestone 3 — Diff-first AI edits (trust + control)
- **Goal**: agent never silently edits disk; it proposes changes as a patch set that the user can review/apply.
- **Primary surface**: AI panel (“Proposed Changes” tab) + Editor diff viewer.
- **Design decisions**
  - “Propose” produces a staged patch under `.ide/staging/` (project-scoped).
  - “Apply” writes to disk only after user approval (or after explicit “Auto-apply” toggle).
  - Patch set stores provenance: toolCallId, command, timestamps, and a short rationale string.
- **Implementation map**
  - `Compass/Services/Tools/FileTools.swift`: add a `mode` argument (`propose|apply`) or introduce parallel “propose_*” tools.
  - `Compass/Services/AIToolExecutor.swift`: treat proposed edits as first-class results with preview UI.
  - New: `Compass/Services/PatchSetStore.swift` (manifest + file blobs).
  - New: `Compass/Components/DiffViewer.swift` (MVP: unified diff + per-file accept/reject).
- **Acceptance criteria**
  - Agent can propose multi-file edits; user can apply/reject per file (MVP) before disk writes.
  - Applying writes exactly what was proposed; rejecting leaves disk untouched.
  - UI clearly shows “what changed” and “which tool caused it”.
- **Out of scope**
  - Perfect per-hunk selection in MVP (start with per-file accept/reject).
- **Test plan**
  - Unit: staging manifest encodes/decodes; applying patch writes expected bytes.
  - Manual: propose change to two files; accept one, reject one.

### Milestone 4 — Checkpoints + rollback (confidence to let agent run wild)
- **Goal**: one-click rollback of any agent-applied change, even without git.
- **Primary surface**: AI panel + Command palette (“Restore checkpoint…”).
- **Scope clarification**
  - This is **file-level** checkpointing (fast APFS clones when available), not full volume snapshots.
  - Store checkpoints under `.ide/checkpoints/<checkpointId>/...` + `manifest.json`.
- **Implementation map**
  - New: `Compass/Services/CheckpointManager.swift` (create/restore/list/delete).
  - `Compass/Services/Tools/FileTools.swift`: before apply, create checkpoint of touched files.
  - Optional: use `copyfile(…, COPYFILE_CLONE)` when supported; fall back to normal copy.
- **Acceptance criteria**
  - Applying a patch set auto-creates a checkpoint of all touched files.
  - Restore brings back exact prior bytes for each file.
  - “Restore” is safe: confirm dialog + preview of which files will change.
- **Out of scope**
  - Restoring deleted files/folders in MVP (optional follow-up).
- **Test plan**
  - Unit: checkpoint manifest roundtrip; restore restores bytes.
  - Manual: edit file, apply, restore, compare.

### Milestone 5 — On-device context engine (quality boost without latency)
- **Goal**: faster + higher-quality agent answers via local retrieval and context packing.
- **Primary surface**: Quick Open, AI “Context” picker, and “Used Context” disclosure per response.
- **Implementation map**
  - Extend `Compass/Services/Index` to support: semantic search, cached summaries, and “related files”.
  - New: `Compass/Services/ContextPackBuilder.swift` (budgeting + selection rules).
  - UI: show what files/snippets were included; allow pin/unpin sources.
- **Acceptance criteria**
  - User can add/remove context sources explicitly.
  - Agent shows which context was used (file list + snippet counts).
  - Context pack builder stays within a configurable budget.
- **Out of scope**
  - Full local LLM inference (separate milestone).
- **Test plan**
  - Unit: context packing respects budget; deterministic selection order.

## Post-milestone roadmap (future)
This section is intentionally **deferred** until Milestones 1–5 are shipped. It’s here to capture direction, but it should not spawn placeholder files or UI until it’s promoted into a Milestone with concrete acceptance criteria.

### AI workflow orchestration
- [ ] Phase 1: Core engine — task graph, loop protection, checkpoints
  - **Depends on**: Milestones 2–4.
  - **Acceptance**: a single run has a stable ID, a reproducible plan, deterministic execution, and a reversible apply step.
- [ ] Phase 2: Orchestration UI — plan/progress, cancel/step controls
  - **Depends on**: Milestone 2.
  - **Acceptance**: users can pause/cancel/step and always see “what is happening right now”.
- [ ] Phase 3: Settings + policy integration — enable/disable features, safety policies, telemetry (optional)
  - **Acceptance**: behavior is configurable per project without hidden global side-effects.

### Context-Aware Assistance
- [ ] Phase 1: Persona system (roles + constraints)
  - **Scope**: extend `AIMode`/settings with “role presets” (e.g., Reviewer, Debugger, Architect) that change tool availability and response format.
  - **Acceptance**: role selection is visible in UI and changes are auditable (shown in the prompt header/logs).
- [ ] Phase 2: Knowledge integration (retrieval + memory)
  - **Depends on**: Milestone 5.
  - **Acceptance**: context packs are explainable, user-controllable, and consistently improve answer quality.
- [ ] Phase 3: UI presentation (context + diffs)
  - **Scope**: improve how we show “used context”, diffs, and references to code locations without overwhelming the user.
  - **Acceptance**: the user can answer “why did the agent do that?” by inspecting context + diff provenance.

### Accessibility Innovations
- [ ] Phase 1: Keyboard-first + Voice optional (agent conversation only)
  - **Rule**: no “voice code editing”; voice is only for high-level agent requests + spoken summaries (optional).
  - **Acceptance**: full IDE usability via keyboard navigation + VoiceOver labels for all major surfaces.
- [ ] Phase 2: High-signal UI for focus (reduce cognitive load)
  - **Scope**: distraction controls, “focus mode”, and progressive disclosure for agent output (collapse/expand reasoning, diffs, logs).
  - **Acceptance**: large agent outputs remain scannable and don’t flood the UI.
- [ ] Phase 3: Accessibility suite hardening
  - **Scope**: audit + fix accessibility identifiers, dynamic type support, contrast, and input methods across the whole app.
  - **Acceptance**: UI tests cover critical flows with accessibility identifiers (no brittle selectors).
