# Post-Refactoring Regression Fix Proposal

> **Status:** Proposal — no code changes applied. Review before implementing.

## Symptoms (what the user experienced)

1. **44k tokens used instantly on "hi".** A brand-new session with the single-word prompt consumed 44k context tokens before producing any output. The agent also jumped into directory-listing — the first tool call should not be exploration when the user simply greets.
2. **Session persistence broken.** App restart no longer recovers the last session or any open tabs. The tab structure explicitly built for multi-session context is reset every launch.
3. **No conversation history retention.** After the agent responds, every subsequent message behaves as if it's the first. Asking "review the plugins" multiple times elicits the same introductory response each time — the agent has no memory of prior turns.

## Root-Cause Analysis

### Issue 1 — 44k context on "hi"

**Primary cause: `SystemPromptAssembler` always loads full prompt (cross-cutting #1 of the audit).**

`SystemPromptAssembler.swift:41-57` was changed from:

```swift
key: input.toolPromptMode == .fullStatic ? "System/tool-system-prompt-full" : "System/tool-system-prompt-concise"
```

to:

```swift
key: "System/tool-system-prompt-full"   // always, ignoring user setting
```

The full variant loads 12 `Tools/v3/*.md` prose documents (each 300–900 bytes) plus `tool-execution-envelope.md`, the expanded `project-root-context.md` (now ~1.5k longer from §6), and for WordPress projects the new `ProjectShapeSummary`. This alone is **~15k tokens more than the concise path** for every first turn.

**Secondary cause: cross-session message leakage.** The `SessionManager` init (`SessionManager.swift:90-108`) loads `historyCoordinator.committedMessages` (the last-run conversation's full message list) and stores it in a snapshot. The `ChatHistoryCoordinator` may then send that snapshot's messages as part of its `requestMessages` — including the notorious BA0AF9 session's 80-tool-call context. If the agent's first send includes old tool-results with file contents, the context window is topped up to 44k.

**Tertiary cause: the project-root-context expansion.** §6 added ~1.5k tokens of bash-cwd documentation to `project-root-context.md`. This was well-intentioned but contributes to the first-turn token budget on every session.

**Files involved:**
- `compass/Services/SystemPromptAssembler.swift:41-57`
- `Prompts/System/tool-system-prompt-concise.md` (still exists, unused)
- `compass/Services/SessionManager.swift:90-108`
- `Prompts/System/project-root-context.md` (expanded in §6)

---

### Issue 2 — Session persistence broken

**Root cause: `Conversation/` stack was deleted from the runtime path.**

The `refocus-v1` branch deleted (before any audit changes):

```
compass/Services/Conversation/Coordination/ConversationCoordinator.swift
compass/Services/Conversation/Coordination/ConversationService.swift
compass/Services/Conversation/Projection/ConversationProjection.swift
compass/Services/Conversation/Projection/PromptProjector.swift
compass/Services/Conversation/Session/SessionRegistry.swift
compass/Services/Conversation/Session/SessionRetentionPolicy.swift
compass/Services/Conversation/Store/ConversationStreamStore.swift
```

These types handled:
- Session lifecycle (creation, suspension, recovery)
- State serialisation (session snapshots to disk)
- Prompt projection (building the message list the AI sees)
- Retention policy (when to archive/delete old sessions)

The replacement `SessionManager` (`SessionManager.swift`) was **designed as a substitute** but was **never wired into the app lifecycle**:
- `saveSnapshot` is present (line 149) but only called internally from `startNew`, `close`, and `restoreSession` — methods that are triggered by **UI actions**, not by app close, background, or periodic save.
- The `init` path (line 70-111) loads saved session IDs from `UserDefaults` and then calls `loadSnapshot(sessionId:)` for each. It calls `historyCoordinator.committedMessages` for the current session. **Crucially, the init does NOT call `restoreSession`** — the history coordinator is populated with whatever `committedMessages` already held (typically empty on cold start), and the user's prior session state (mode, input text, live preview, subject) is lost.

**Files involved:**
- `compass/Services/SessionManager.swift:70-111` (init — no restoreSession call)
- `compass/Services/ConversationManager.swift:160-164` (creates SessionManager but never restores)
- `compass/Services/ChatHistoryCoordinator.swift` (committedMessages may not be persisted to disk)

---

### Issue 3 — No conversation history retention

**Root cause: `shouldForceInitialExecutionFollowup` triggers on every clean assistant turn and rebuilds the message list from scratch.**

`ToolLoopHandler.swift:99-131` (the pre-loop force-execution followup path) calls `buildFocusedExecutionMessages` whenever:
1. The mode is agentic
2. The model's response has no tool calls
3. `shouldForceInitialExecutionFollowup(...)` returns true

`buildFocusedExecutionMessages` (`ToolLoopUtilities.swift:164-198`) does this at line 189:

```swift
var messages = historyMessages.filter { $0.role == .system && !$0.content.contains("focused execution mode") }
messages.append(ChatMessage(role: .system, content: parts.joined(separator: "\n\n")))
messages.append(ChatMessage(role: .user, content: userInput))
```

**User and assistant messages are entirely filtered out.** The model sees only system prompts + a restated `userInput`. Every prior turn is erased.

This path fires when:
- User says "hi" → agent responds "Hi, how can I help?" (no tool calls) → `shouldForceInitialExecutionFollowup` returns true because the response text has no tool calls and no artefacts were produced → `buildFocusedExecutionMessages` strips the history → the followup send makes the agent respond AGAIN as if the user just said "hi."
- User says "review plugins" → agent does 5 reads then emits a summary (no tool calls in final turn) → same flow strips history → next "look more closely" message sees only system prompts + "look more closely."

**Contributing cause: the §11 read-only guard is correct but `shouldForceInitialExecutionFollowup` is not gated by it.** The §11 fix only covers `requestLikelyRequiresMutation` (used for recovery paths INSIDE the while-loop). The pre-loop followup at line 99 does not check the read-only intent guard — it fires for ANY agentic-mode message, including "hi" and "review plugins."

**Files involved:**
- `compass/Services/CloudPipeline/ToolLoopHandler.swift:99-131` (pre-loop)
- `compass/Services/CloudPipeline/ToolLoopHandler.swift:2843-2879` (`shouldForceInitialExecutionFollowup`)
- `compass/Services/CloudPipeline/ToolLoopUtilities.swift:164-198` (`buildFocusedExecutionMessages`)

---

## Proposed Fixes

### Fix 1 — Restore prompt-conciseness control (44k context)

**Goal:** Keep the full prompt's guardrails but don't force 15k extra tokens onto every first turn.

**Change 1a:** Revert `SystemPromptAssembler.swift` to respect `input.toolPromptMode`. The `tool-system-prompt-full.md` **already** contains the critical guardrails — it was always loaded for users who chose `fullStatic`. Users who chose `concise` deliberately traded guardrail surface for cost — that tradeoff belongs to them, not to us.

**Change 1b:** Audit `tool-system-prompt-concise.md` and add the ONE missing sentence that caused the bash-exploration issue: *"For codebase exploration, use `search`, `glob`, or `ls` — never `bash find`/`grep`/`rg`."* This single line carries the most important guardrail without the full 1.5k-token surface.

**Change 1c:** Session snapshots loaded at startup (`SessionManager.init`) should trim the message array to the most recent N messages before storing. `historyCoordinator.committedMessages` may contain 80+ tool-result messages from a prior session — these should not leak into the first turn of a new session.

**Change 1d:** Add a token-budget log line to `ConversationSendCoordinator` or `OpenRouterChatRequest` that prints the estimated token count per request. This makes the 44k visible to operators without requiring session file inspection.

**Files to change:**
- `compass/Services/SystemPromptAssembler.swift:41-57` — revert to conditional
- `Prompts/System/tool-system-prompt-concise.md` — add single exploration guardrail
- `compass/Services/SessionManager.swift:70-111` — trim loaded message history
- `compass/Services/OpenRouterChatRequest.swift` (or similar) — token-budget log

---

### Fix 2 — Restore session persistence

**Goal:** The app must recover the last session's state (open tabs, conversation history, mode, input text) on relaunch.

**Change 2a:** In `ConversationManager.init` (after `sessionManager` is created), call `restoreSession(sessionManager.selectedId)` to push the recovered snapshot into `historyCoordinator`. The `SessionManager.init` already loads the snapshots — we just need to activate the selected one.

```
// After ConversationManager.init, line ~198:
Task { @MainActor in
    var (input, preview, status, mode) = ("", "", "", AIMode.chat)
    sessionManager.restoreSession(
        sessionManager.selectedId,
        input: &input,
        livePreview: &livePreview,
        liveStatusPreview: &liveStatusPreview,
        mode: &mode
    )
    self.currentInput = input
    self.liveModelOutputPreview = preview
    self.liveModelOutputStatusPreview = status
    self.currentMode = mode
}
```

**Change 2b:** Add a save hook. `ConversationManager` should call `sessionManager.saveSnapshot(...)` on:
- `deinit` (app close)
- `NSApplication.willTerminate` (via NotificationCenter in `compassApp.swift`)
- Every successful `sendMessage` completion (so mid-session state is preserved in case of crash)

**Change 2c:** Verify that `SessionManager.loadSessionOrder`/`saveSessionOrder` are using the correct `UserDefaults` domain. The `AppRuntimeEnvironment` may use a suite-specific `UserDefaults` that differs from the standard one. Check line 41-42 of the SessionManager for the key constants — they use `UserDefaults.standard` which is correct, but verify via a debug log.

**Files to change:**
- `compass/Services/ConversationManager.swift` — call `restoreSession` in init, call `saveSnapshot` on send-complete and app-close
- `compass/compassApp.swift` — register `willTerminate` handler

---

### Fix 3 — Stop conversation history erasure

**Goal:** The agent must see the full conversation history that the user sees. Recovery paths must not strip user/assistant messages.

**Change 3a:** Gate `shouldForceInitialExecutionFollowup` on read-only intent. The pre-loop force-execution path at `ToolLoopHandler.swift:99-102` should not fire when the user's intent is read-only (review, explain, audit, assess). Add `!requestIsReadOnlyIntent(userInput)` to the condition:

```swift
if (mode.isAgentic),
   currentResponse.toolCalls?.isEmpty ?? true,
   !availableTools.isEmpty,
   !requestIsReadOnlyIntent(userInput),       // §FIX: skip for review/chat prompts
   shouldForceInitialExecutionFollowup(...)
```

**Change 3b:** `buildFocusedExecutionMessages` should NOT filter out user/assistant messages entirely. The current code at `ToolLoopUtilities.swift:189` strips history. Instead, preserve the last N user/assistant pairs (or at least the user's current message) alongside the system prompts:

```swift
// OLD: var messages = historyMessages.filter { $0.role == .system && ... }
// NEW: keep system messages + last few user/assistant exchanges
let recentExchanges = historyMessages
    .filter { !$0.isDraft && ($0.role == .user || $0.role == .assistant) }
    .suffix(4)  // keep last 2 user+assistant pairs
let preservedSystem = historyMessages
    .filter { $0.role == .system && !$0.content.contains("focused execution mode") }
var messages = preservedSystem
messages.append(contentsOf: recentExchanges)  // user/assistant messages AFTER system prompts
messages.append(ChatMessage(role: .system, content: parts.joined(separator: "\n\n")))
messages.append(ChatMessage(role: .user, content: userInput))
```

This preserves the natural conversation flow while still injecting the recovery system message.

**Change 3c:** Limit `shouldForceInitialExecutionFollowup` to fire at most once per `handleToolLoopIfNeeded` invocation. Currently it fires in the pre-loop path AND potentially in the mid-loop paths (lines 1064, 1294, 1350). Add a `hasAlreadyFiredExecutionFollowup` guard.

**Files to change:**
- `compass/Services/CloudPipeline/ToolLoopHandler.swift:99-102` — add read-only guard
- `compass/Services/CloudPipeline/ToolLoopUtilities.swift:189` — preserve user/assistant in recovery messages
- `compass/Services/CloudPipeline/ToolLoopHandler.swift` — fire-prevention guard

---

## Priority order

| # | Fix | Effort | Risk | Impact |
|---|---|---|---|---|
| 3 | Conversation history erasure | Small | Low | Critical — every turn breaks |
| 2 | Session persistence | Medium | Medium | High — UX regression |
| 1 | 44k context explosion | Medium | Low | High — cost + delay |

**Recommended order:** Fix 3 first (quick, high-impact, unblocks everything), then Fix 2, then Fix 1.

---

## What NOT to change (lessons from the audit refactoring)

1. **Do not revert §1 (edit old_string/new_string).** The new edit mode is pure addition, no regression risk. The `old_string`/`new_string` parameters are optional — the line-range path is untouched and all existing tests pass on it.

2. **Do not revert §6 (bash cwd docs).** The expanded `project-root-context.md` adds tokens but removes the most common bash error. To reduce token cost, move the concrete examples to `bash.md` and keep only the one-paragraph rule in `project-root-context.md`.

3. **Do not revert §7 (WordPress index exclusion).** The `IndexFrameworkDetection` only fires on fresh seed — no existing project files are touched. It is a pure improvement.

4. **Do not revert §8 (anti-amnesia prior-work summary).** The injection is gated on `!readPaths.isEmpty || toolExecCount > 0` — it returns `""` for brand-new sessions. It was not the cause of any of these three regressions.

5. **Do not revert §11 (read-only intent guard).** The guard short-circuits `requestLikelyRequiresMutation` to `false` for review/audit prompts. It does not affect history retention or session persistence. It should actually be EXPANDED (per Fix 3a) to gate `shouldForceInitialExecutionFollowup` as well.

---

## Verification checklist

After applying fixes, verify:

- [ ] Cold-start app → last conversation tab is active, messages are visible, mode and input are restored
- [ ] Send "hi" → agent responds, next "review plugins" → agent reads files and delivers analysis without re-introducing itself
- [ ] Token count for first turn ≤ 15k (measured from provider response billing metadata)
- [ ] Open 3 tabs, switch between them → each has its own messages and mode
- [ ] Relaunch app → all 3 tabs are still present with correct content
- [ ] Existing `IndexAndToolsTests` pass (new edit tests, framework detector tests)
- [ ] `./run.sh build` succeeds