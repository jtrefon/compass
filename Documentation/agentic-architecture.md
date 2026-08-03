# Agentic Architecture Spec (compass)

## 1) Mission

Build the best agentic, fully independent IDE experience with:

- deterministic behavior
- user-controlled mode and reasoning
- strong quality gates
- minimal technical debt
- excellent observability

This spec also defines:

- a multi-phase execution framework (reasoning → planning → execution)
- a LangGraph-inspired native graph runtime abstraction
- a RAG subsystem used for context extension and code recall
- a dual-model strategy (local small model + optional remote large model) with an "airplane mode"

## 2) Core invariants (must never be violated)

### 2.1 User-owned Mode (Chat / Agent)

- **Invariant**: `AIMode` is controlled **only** by the user/UI.
- **Prohibited**:
  - any internal stage flipping `.agent` ↔ `.chat`
  - any prompt content suggesting switching modes
  - any “fallback” that uses a different mode than the user selected
- **Allowed**:
  - internal stages may change **tool permissions** (subset of tools) while keeping the same `AIMode`.

### 2.2 User-owned Reasoning (on/off)

- **Invariant**: `reasoningEnabled` is controlled **only** by the user.
- **Prohibited**:
  - internal toggling of reasoning
  - prompts that allow the model to decide whether to include reasoning
- **Required**:
  - if `reasoningEnabled == true` and user mode is Agent, reasoning is **enforced** on every stage (see §4)

### 2.3 QA is advisory only

- **Invariant**: QA must **not** rewrite the user-visible final answer.
- QA emits a **QA report artifact** (structured) that can be:
  - displayed to the user (optional)
  - fed back as internal guidance for the next iteration (optional)
- QA never has write/edit/delete capability.

### 2.4 Tool permissions are stage-owned, not mode-owned

- `AIMode` is user intent.
- Tool access is an internal policy decision per stage, always consistent and logged.

### 2.5 Delivery/finished state is authoritative and cannot be erased

- Completion must be tracked in run state and logs.
- It must not be removable by QA or “final response retries”.

## 3) Architecture overview

### 3.1 Components

- **ConversationManager**
  - owns UI state (`currentMode`, `currentInput`, `isSending`)
  - starts a run with a `runId`

- **ConversationSendCoordinator**
  - owns the orchestration flow
  - must not mutate `AIMode` or `reasoningEnabled`

- **AIInteractionCoordinator**
  - retrying transport wrapper
  - builds augmented context via `ContextBuilder`
  - sends requests via `AIService`

- **AIService (OpenRouterAIService)**
  - maps messages to OpenRouter schema
  - appends deterministic system prompt content based on policy (see §5)

- **ToolExecutionCoordinator**
  - executes tool calls
  - streams progress messages into history

- **Policy owner** (new)
  - single authoritative decision-maker for:
    - tool subset per stage
    - prompt set per stage
    - reasoning requirements per stage
  - must be pure / deterministic and unit tested

- **PromptRepository** (new)
  - loads all prompts from markdown files
  - supports variable interpolation

- **QA reviewer** (refactored)
  - produces advisory QA report
  - uses restricted read-only tool set

- **Context compression** (existing or refactored)
  - summarizes older history deterministically
  - maintains “rolling memory” without context pollution

- **Index + Local memory** (existing CodebaseIndex)
  - supports semantic retrieval
  - stores structured local memories (project context)

- **Graph runtime** (new)
  - executes a directed graph of nodes (LangGraph-inspired)
  - each node is a deterministic step type (reasoning, planning, tool execution, QA)
  - nodes exchange a shared run state (see §12)

- **RAG subsystem** (new)
  - maintains indexes (code, docs, memories)
  - provides retrieval results to the agent runtime deterministically (inputs/outputs are logged)

- **Model adapter layer** (new)
  - isolates model-specific templates and tool calling behavior behind a single protocol
  - supports:
    - local model only (airplane mode)
    - remote model only
    - hybrid mode (local model used for RAG and small tasks)

### 3.2 Data flow (high level)

1. User sends message in UI
2. Run starts with `runId`, `AIMode`, `reasoningEnabled`
3. Coordinator/runtime performs:
   - Deep reasoning (Stage: `deep_reasoning`)
   - Strategic plan build (Stage: `strategic_planning`)
   - Tactical planning (Stage: `tactical_planning`)
   - Execution loop (Stage: `execution`) with tool loops
   - QA advisory review (Stage: `qa_tool_output_review`, `qa_quality_review`) (non-mutating)
4. Final message appended
5. Run snapshot persisted

Each phase must emit a short user-visible progress update (even 1–2 sentences) for traceability.

## 4) Reasoning enforcement model (macro + micro)

### 4.1 Macro warmup reasoning (once per user message)

Goal: high-quality “pre-run warmup” that plans the work.

- Stage: `warmup`
- Required when:
  - `mode == Agent` and `reasoningEnabled == true`
- Output:
  - `<ide_reasoning>` block with required sections
  - plus a short user-visible statement of next steps

**Macro requirements**:
- Analyze: interpret user request
- Research: identify what must be inspected (files/entrypoints/logs)
- Plan: explicit milestones
- Reflect: risks and assumptions
- Action: immediate next tool actions
- Delivery: must start with `NEEDS_WORK` until complete

### 4.2 Micro reasoning between steps (every subsequent agentic request)

Goal: “small reflection” to help the model converge without rehashing full plan.

- Stage: `micro_step`
- Required when:
  - `mode == Agent` and `reasoningEnabled == true`

**Micro requirements**:
- Reflect briefly on:
  - what just happened (tool outputs, errors)
  - what we will do next
  - why that next step is correct
- Keep concise: 3–8 bullets total.

### 4.3 Reasoning retention policy (avoid context pollution)

- The UI may display reasoning for transparency.
- The next model request should not be polluted by old reasoning.

#### Rule

- Persist only a compact **ReasoningOutcome** in the conversation chain.
- Discard the full `<ide_reasoning>` text from subsequent model history.

#### ReasoningOutcome content

- `plan_delta`: what changed in plan
- `next_action`: what tool call(s) will be made next
- `known_risks`: one-line
- `delivery_state`: `DONE` / `NEEDS_WORK`

### 4.4 QA reasoning

- If `reasoningEnabled == true`, QA must also include reasoning,
  but using the **micro format** (short) and must not rewrite the answer.

## 4.5 Multi-phase execution framework (authoritative)

The agent execution framework is a fixed sequence of phases. The runtime may repeat phases (e.g., execution loops) but must not skip required phases silently.

### Phase A: Deep reasoning

- **Goal**: interpret the user request, identify risks, select approach.
- **Output**:
  - reasoning artifact (internal)
  - user-visible progress update (short)
- **Inputs**:
  - user input
  - retrieved context (RAG)

### Phase B: Strategic planning

- **Goal**: build a small set of outcome-oriented milestones.
- **Output**:
  - strategic plan (few steps)
  - user-visible progress update

### Phase C: Tactical planning

- **Goal**: convert a selected strategic step into context-window-safe substeps that are executable even with limited history.
- **Output**:
  - tactical plan for the next milestone
  - user-visible progress update

### Phase D: Execution loop

- **Goal**: execute one tactical substep at a time.
- **Loop**:
  - research/inspect (via RAG + tools)
  - implement
  - review
  - update plan state
  - user-visible progress update

## 12) Graph runtime (LangGraph-inspired) mapping

### 12.1 Node model

- Nodes are small single-responsibility steps with:
  - `id`
  - `kind` (reasoning, strategic_planning, tactical_planning, tool_execution, qa)
  - `input` (run state slice)
  - `output` (state patch)

### 12.2 State model

Run state must be a single struct that is serializable and loggable. It must include:

- user input
- current phase
- strategic plan
- tactical plan
- last tool calls/results
- delivery state
- run snapshots pointers

### 12.3 Edges and control

- The runtime selects next node based on:
  - current phase
  - completion flags
  - failure signals

The runtime must enforce max-iteration limits and write snapshots for every transition.

## 13) RAG + dual-model strategy

### 13.1 Responsibilities

#### Local small model (always available)

- embeddings for indexing
- retrieval summarization / context compression
- code completion and small administrative tasks
- optional airplane-mode main agent model (no remote calls)

#### Remote large model (optional)

- deep reasoning and complex planning
- tool-heavy execution on large tasks

### 13.2 Airplane mode
- When enabled:
  - remote model is disabled
  - agent runtime continues using the local model adapter
  - RAG remains available
  - quality gates should adapt (e.g., simpler QA or local-only checks)

### 13.3 Retrieval usage points
- Deep reasoning should request retrieval first (project entry points, relevant files).
- Tactical planning should request retrieval scoped to the current milestone.
- Execution steps should request retrieval for:
  - symbol lookup
  - cross-file impact analysis
  - tool selection hints

## 14) Testing strategy (headless)

### 14.1 Contract harness
- A headless XCTest harness must validate orchestration contracts without launching UI.
- Baseline scenarios:
  - orchestration lifecycle (write_file + replace_in_file)
  - multi-file scaffolding (write_files)

The harness should be runnable via `./run.sh harness` and must only depend on orchestration + tools.

CI must run `./run.sh test` only. The harness runner is intentionally separate because it may require a configured model runtime that is not available in CI.

## 5) Prompts (externalized to Markdown)

### 5.1 Prompt inventory
All prompts live under `compass/Prompts/` (exact structure can be adjusted):

- `Prompts/base/system.md`
- `Prompts/base/project_root_context.md`
- `Prompts/agent/mode_addition.md`
- `Prompts/agent/reasoning_macro.md`
- `Prompts/agent/reasoning_micro.md`
- `Prompts/agent/tool_loop_context.md`
- `Prompts/agent/user_input_request_block.md`

 Current incremental migration (already in repo):

- `Prompts/ConversationFlow/Corrections/tool_loop_focused_execution.md`
- controller-owned autonomous no-user-input recovery in the conversation flow handlers
- `Prompts/ConversationFlow/QA/tool_output_review_system.md`
- `Prompts/ConversationFlow/QA/quality_review_system.md`

- `Prompts/qa/system.md`
- `Prompts/qa/review_micro_reasoning.md`
- `Prompts/qa/report_schema.md`

### 5.2 Prompt composition rules
- System prompt is composed deterministically:
  - base prompt
  - project root context
  - mode addition (derived from user mode, but never instructs switching)
  - stage prompt (warmup/tool/micro/delivery/qa)
  - reasoning prompt (only if user enabled)

### 5.3 Prompt interpolation
Allowed variables:
- `{{project_root}}`
- `{{user_input}}`
- `{{tool_summary}}`
- `{{last_step_outcome}}`

## 6) Tool policy (capability matrix)

### 6.1 Principle
- Tool access depends on stage.
- Never change `AIMode`.

### 6.2 Suggested tool sets
- **Agent execution (act/tool_followup)**
  - full tool set for edits + reads

- **Delivery-only step**
  - tools disabled (empty list)

- **QA review (read-only)**
  - index read/search/list only
  - no patch/write/delete

## 7) Context compression (history summarization)

### 7.1 Purpose
Prevent context window overflow while preserving continuity.

### 7.2 Requirements
- Summarize old turns into a structured summary message:
  - goals
  - decisions
  - current plan
  - open issues
  - important tool outputs
- Do not include old `<ide_reasoning>` blocks.

### 7.3 Trigger policy
- Trigger based on:
  - message count threshold
  - token estimate threshold
- Always deterministic, logged.

## 8) Index + local memory integration

### 8.1 Retrieval
- Use CodebaseIndex to:
  - locate entry points
  - retrieve relevant symbols
  - retrieve local memories

### 8.2 Memory writing policy
- Memories are written only when:
  - a run completes successfully
  - a stable decision is made (architecture choice)
- Memory entries should be concise and queryable.

### 8.3 Memory tiers
- project-level facts (paths, build commands)
- architecture-level decisions
- recent run outcomes

## 9) Observability and logging (must be airtight)

### 9.1 Required log fields for every OpenRouter request
- `conversationId`
- `runId`
- `userMode` (the UI-selected mode)
- `stage`
- `toolCount`
- `reasoningEnabled`

### 9.2 Assertions
- **Mode invariance**: log and assert the request mode equals the user-selected mode.
- **Reasoning invariance**: if enabled, stage prompt includes reasoning instruction.
- **Tool invariance**: stage tool set matches policy.

## 10) Failure modes and recovery

### 10.1 Empty model response
- Stage-owned recovery prompt.
- Must not switch mode.

### 10.2 Model asks user for diffs/files
- Stage-owned correction prompt.
- Must proceed autonomously.

### 10.3 Tool failures
- structured recovery guidance
- retry with changed parameters

## 11) Project tracker (refactor checklist)

### 11.1 Invariants
- [ ] Remove any internal code that can switch `.agent` ↔ `.chat`
- [ ] Remove any prompt text suggesting mode switching
- [ ] Make `reasoningEnabled` strictly user-owned and deterministic

### 11.2 Prompts
- [x] Create `Prompts/` directory
- [ ] Move all inline prompts from Swift into `.md`
- [x] Add `PromptRepository` + interpolation

### 11.3 Policy
- [x] Implement centralized `ConversationPolicy`
- [ ] Unit test: stage -> tools/prompt/reasoning

### 11.4 QA
- [x] Replace QA rewriting with advisory `QAReport`
- [x] Restrict QA tools to read-only
- [x] Ensure QA never mutates final message

### 11.5 Reasoning
- [x] Macro warmup reasoning on each user message (Agent + reasoning enabled)
- [x] Micro reasoning on each subsequent agentic step
- [x] Strip full reasoning from history; persist `ReasoningOutcome`

### 11.6 Context compression
- [x] Define summarization trigger
- [x] Persist structured summary
- [x] Exclude `<ide_reasoning>` from summaries

### 11.7 Local memory
- [x] Define memory write policy
- [ ] Add tests for memory retrieval usage

### 11.8 Observability
- [x] Add `runId` + `stage` to OpenRouter logging
- [x] Assert invariants in debug builds
