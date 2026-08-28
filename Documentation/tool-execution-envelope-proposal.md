# Proposal: First-Line Tool Execution Envelope (logfmt + OTel-aligned)

**Status:** DRAFT for sign-off
**Author:** opencode (investigation + scoping)
**Goal:** Stop the "agent re-runs the same command multiple times" failure by giving every tool result a
consistent, machine-readable first-line envelope (`tool` + `params` + `status`), and teaching the
model in the main system prompt exactly what that envelope is and how to read it — so it anticipates
execution and does not repeat an action it can already see succeeded.

---

## 1. Investigation — we are not reinventing the wheel

Two industry standards govern this:

- **logfmt** (Heroku, 2013; see brandur.org/logfmt, Splunk & Grafana best-practice
  recommendations). Compact `key=value` pairs on a single line. Human- *and* machine-readable. The
  user's proposed `[tool=file_read,param=src/app/global.css,status=success]` **is logfmt** with a
  bracket frame. This is the proven format for dense single-line structured records.
- **OpenTelemetry GenAI semantic conventions** (`github.com/open-telemetry/semantic-conventions-genai`,
  now a standalone repo). The emerging standard for AI tool-execution *schema*:
  `gen_ai.tool.name`, `gen_ai.tool.call.arguments`, `gen_ai.tool.call.id`,
  `gen_ai.response.finish_reasons`. Tells us the canonical **field names** to align to, so the
  envelope is future-proof for telemetry/observability export without putting `gen_ai.` noise in front
  of the model.

**Decision:** use **logfmt syntax** (matches the user's instinct, industry-proven) + **OTel-aligned field
names** (so identity maps 1:1 to `gen_ai.tool.*`). No new grammar invented.

## 2. The envelope (single source of truth)

One bracket-framed logfmt line, emitted as the **first line** of every tool result:

```
[tool=<resolved_name> param.<k>=<v>... status=<success|partial|error>]
```

Examples (exactly the shape the user proposed):

```
[tool=file_read param.path=src/app/global.css status=success]
[tool=run_command param.cmd="npm test" param.cwd=./web status=success]
[tool=write_file param.path=src/App.tsx status=error]
```

Rules:
- `tool` — the **resolved** tool name the executor actually dispatched (not the raw model string).
- `param.<k>` — one `key=value` pair **per argument actually used**, normalized (paths relative to
  project root where possible). Multiple args → multiple `param.` pairs. This is the *identity* the
  model and the engine both key deduplication on.
- `status` — enum `success | partial | error` (aligned to OTel `finish_reasons` spirit).
- The envelope is a **prefix**. Detail follows on subsequent lines using the existing
  `ToolFeedbackFormatter` shape (`message:`, `content:`, `error_code:`). The model sees the
  envelope first; parsers read the first line.
- Delimiter: `[` `]` frames the envelope so it is unambiguous to extract from surrounding prose
  and cannot be confused with tool output text.

### Mapping to OpenTelemetry GenAI (for future telemetry export, not for the model)
| Envelope field | OTel GenAI attribute |
|---|---|
| `tool` | `gen_ai.tool.name` |
| `param.*` | `gen_ai.tool.call.arguments` |
| `status` | `gen_ai.response.finish_reasons` |
| (tool call id) | `gen_ai.tool.call.id` |

## 3. Existing assets (reuse)

- `ToolFeedback` / `ToolFeedbackFormatter` (`compass/Services/AITool.swift:159-225`) already emit
  `status:` / `message:` / `content:` / `error_code:`. **Extend** to emit the bracket envelope as the
  first line and add `tool:` + `params:`.
- `ToolFeedback` carries `status` + `message` but **not** the tool name or the resolved arguments. The
  legacy bridge `ToolAdapter.execute` (`AITool.swift:259`) returns `ToolFeedback.success(result)`,
  discarding `request.toolName` + `request.arguments`. **Fix the bridge** so the envelope has real data.
- `Prompts/Tools/v3/feedback-format.md` already drafts this contract (without `tool:`/`params:`). Adopt
  and extend it.
- `ToolLoopHandler` already tracks `previouslyCompletedToolCallSignatures` — the envelope gives the
  model the same identity the engine uses.

## 4. Prerequisite (land first)

`SystemPromptAssembler` (`compass/Services/SystemPromptAssembler.swift:43-59`) still loads
`Tools/v2/*` prompts, but **every `Prompts/Tools/v2/*.md` was deleted** by the prior agent, and the
new `Prompts/Tools/v3/*` set is untracked and unwired. The "## Tool Reference" section is currently
empty (loader silently skips missing keys).

**Action:** make `v3` the canonical tool-prompt source; replace the `v2` key list with
`v3` keys: `read`, `write`, `edit`, `ls`, `glob`, `search`, `rm`, `context`, `web_search`,
`web_fetch`, `bash`, `plan`, `feedback-format`.

## 5. Implementation

### 5.1 Envelope type + formatter (single source of truth)
- New `compass/Services/Tools/ToolExecutionEnvelope.swift`:
  ```swift
  struct ToolExecutionEnvelope: Sendable, Codable {
      let tool: String
      let params: [String: String]          // normalized, e.g. ["path": "src/app/global.css"]
      let status: ToolEnvelopeStatus        // success | partial | error
      let message: String?
      /// "[tool=file_read param.path=src/app/global.css status=success]"
      func firstLine() -> String
  }
  enum ToolEnvelopeStatus: String, Sendable, Codable { case success, partial, error }
  ```
- Extend `ToolFeedback` (`AITool.swift`) with `toolName: String?` and `params: [String: String]`,
  populated by the executor (it knows the resolved name + normalized args).
- `ToolFeedbackFormatter.format(_:)` prepends `envelope.firstLine()` to the emitted text.

### 5.2 All tools emit it consistently (~14 `AITool` conformances + `Tool`-protocol tools)
- New `Tool`-protocol tools already return structured `ToolFeedback` → just ensure `toolName`/`params`/
  `status` are set (no empty `message`).
- Legacy `AITool` tools: `ReadFileTool`, `WriteFileTool`, `DeleteFileTool`, `PatchFileToolAdapter`,
  `ListFilesTool`, `FindFileTool`, `SearchProjectTool`, `WebBrowseTool`, `ContextTool`,
  `GoogleWebSearchTool`, `PinnedRule*`, `PlanTool`. Fix `ToolAdapter.execute` to construct
  `ToolFeedback(toolName: request.toolName, params: normalized(request.arguments), status:, message:)`.
  A single helper `normalizedParams(_:)` lives in the envelope file.

### 5.3 System-prompt contract (the "explain what is what" part)
- New `Prompts/System/tool-execution-envelope.md`:
  - "After every tool call you receive a **first-line execution envelope** in logfmt. It is the
    authoritative record of what ran."
  - The grammar from §2, with the user's exact example.
  - One worked pair: a `run_command` success envelope + a `write_file` success envelope in context.
  - The anti-repeat rule, stated plainly: **"If a `status=success` envelope for `tool=<X>` with the
    same `param.*` is already present in the conversation, that action is complete — do not call the same
    tool with the same params again. Continue from its result."**
- Wire into `SystemPromptAssembler.assemble(...)`: append the envelope section when `input.hasTools`,
  alongside the `v3` tool reference from §4.

### 5.4 Engine dedup reinforces (defense in depth, no new loop branches)
- Add a small `ToolEnvelopeParser` (read first-line `[...]` → `ToolExecutionEnvelope`) so the engine
  can extract the same identity the model sees. Feed it into the existing
  `previouslyCompletedToolCallSignatures` check. No control-flow change in `ToolLoopHandler`.

### 5.5 Tests
- `compassHarnessTests`: assert the `ChatMessage` for a completed tool has the envelope as its first
  line (new test or extend `ToolLoopDropoutHarnessTests`).
- Harness scenario: model is handed a prior `status=success` envelope with identical params → assert the
  loop does **not** re-execute that tool (guards the original "same command multiple times" bug at the
  model-decision layer, not just the message-dedup layer fixed earlier).

## 6. Non-goals / risks

- **Not** changing agent-loop control flow or `BranchReviewNode` retry policy (separate open item).
- **Not** adding a pre-action "intent envelope" this pass — result envelope only. (Follow-up if wanted.)
- **Risk:** more tokens per tool result. Mitigation: the envelope is one short line and can *replace* the
  ad-hoc `"Done -> Next -> Path:"` handoff prose the model currently emits. Validate budget in
  `StreamingPerformanceHarnessTests` before merge.
- **Risk:** a tool returning prose that itself contains `[tool=...]` could be misparsed. Mitigation: the
  envelope is a formatter-owned prefix, not free tool text; parser only reads the **first** line and only
  when it matches `^\[tool=.*status=\w+\]$`.

## 7. Full rollout

**Phase 0 — prerequisite (§4).** Wire `v3` into `SystemPromptAssembler`; delete the dead `v2` key list.
Land alone; verify tool-reference section renders.

**Phase 1 — envelope type + formatter (§5.1).** Add `ToolExecutionEnvelope` + extend
`ToolFeedback`/`ToolFeedbackFormatter`. No behavior change yet (fields optional). Build green.

**Phase 2 — all tools populate it (§5.2).** Fix `ToolAdapter`; audit the ~14 legacy tools +
`Tool`-protocol tools. Each tool result now carries real `tool`/`params`/`status`.

**Phase 3 — system-prompt contract (§5.3).** Add `tool-execution-envelope.md`; inject when
`hasTools`. Model now expects + reads the envelope.

**Phase 4 — engine parser + dedup reinforcement (§5.4).** `ToolEnvelopeParser` feeds existing
signature dedup. No new loop branches.

**Phase 5 — tests + validation (§5.5).** Add harness tests; run
`./run.sh harness ToolLoopDropoutHarnessTests`, `./run.sh build`, and
`StreamingPerformanceHarnessTests` (token budget). Manual agent-mode end-to-end: confirm no redundant
re-execution of identical commands.

## 8. Sign-off checklist

- [ ] §4 `v3` wired; `v2` keys removed.
- [ ] §5.1 `ToolExecutionEnvelope` + formatter first-line output.
- [ ] §5.2 `ToolAdapter` carries `toolName`/`params`; all tools reviewed.
- [ ] §5.3 `tool-execution-envelope.md` created + injected when `hasTools`.
- [ ] §5.4 `ToolEnvelopeParser` reinforces existing dedup.
- [ ] §5.5 harness tests added; `ToolLoopDropoutHarnessTests` green.
- [ ] `./run.sh build` clean; `StreamingPerformanceHarnessTests` token budget acceptable.
- [ ] Manual: agent mode — no identical-command re-execution.

## 9. Open questions (need your call before implementation)

1. **Param verbosity** — full args vs. normalized signature for the anti-repeat rule? *Recommend:*
   normalized `param.<k>=<v>` pairs (the same identity the engine dedups on), key args inline.
2. **Scope this pass** — result envelope only (*recommended*) or also pre-action intent envelope?
3. **Telemetry export** — should we also emit these as OTel `gen_ai.tool.*` span events now, or
   leave that for a later observability pass? *Recommend:* leave for later; envelope shape already maps 1:1.
