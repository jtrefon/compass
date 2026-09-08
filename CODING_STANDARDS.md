# Coding Standards

Authoritative engineering rules for **Compass**. Companion to
[`DESIGN_STANDARDS.md`](./DESIGN_STANDARDS.md) (UI/UX) and [`AGENTS.md`](./AGENTS.md)
(engine live-path invariants). Where they overlap, `AGENTS.md` wins for the engine path,
`DESIGN_STANDARDS.md` wins for UI, this document wins for everything else.

> **Perfection is a journey, not a destination.** These rules are the bar we hold
> ourselves to — not a checklist that is always fully green. When you fall short, fix it
> forward and say so in the PR. What is *never* acceptable is silently shipping something
> you know is below the bar.

## 0. What we value

1. **Correctness and reliability over speed.** We do not ship "quick" code. We ship the
   best version we know how to write, then verify it.
2. **Simple and readable over clever.** Any contributor should be able to read a file and
   understand it without the author present.
3. **Small and focused over broad.** One change, one problem. One responsibility, one place.
4. **Verifiable over assumed.** If it isn't tested, it isn't done. If it can't be tested,
   restructure it until it can.
5. **Deleted over dormant.** Dead code is a liability, not an asset. If it is not on the
   live path, delete it (AGENTS.md §Engine live path).

## 1. Architecture

### 1.1 Clean architecture

The app is layered, and dependencies point **inward**:

```
UI / Presentation  (Compass/Components, Views)
      ↓
Application / Orchestration  (Coordinators, Managers, Tool Loop)
      ↓
Domain / Services  (AIService protocol, tools, repositories)
      ↓
Infrastructure / Adapters  (OpenRouter, MLX, FAISS, SQLite, file store)
```

Rules:

- **A layer never reaches past its neighbor.** UI talks to coordinators, not to the vector
  store or the MLX generator directly.
- **Boundaries are protocols, not concrete types.** Depend on the seam
  (`LocalModelGenerating`, `EngineMemoryMonitoring`, `ConversationHistoryProviding`,
  `AIService`), inject the implementation. This is what makes the harness and unit tests
  possible without mocks of the world.
- **The harness orchestrates; it never implements** (cardinal rule 1). Test code calls
  production code; it never re-implements it.

### 1.2 SOLID, mapped to this codebase

| Principle | What it means here | Example |
|---|---|---|
| **S**ingle Responsibility | A type has one reason to change. Actors/classes should fit in one sentence. | `LocalModelToolLoop` owns loop orchestration only; `LocalModelIterationGuide` owns repetition guidance; `LocalModelToolLoopLogger` owns telemetry. |
| **O**pen/Closed | Extend behavior by adding, not by editing existing cases. | New iteration guidance is a new method on the guide, not a new branch in the loop. |
| **L**iskov | A protocol's implementations are interchangeable without callers knowing. | `EngineMemoryMonitoring`: `ProcessMemoryMonitor` (prod) and `MockMemoryMonitor` (tests) satisfy the same contract. |
| **I**nterface Segregation | Protocols are small and role-shaped. | `CompletionInferring`, `InlineCompletionProviding`, `ConversationHistoryProviding` are narrow seams, not god-protocols. |
| **D**ependency Inversion | High-level policy depends on abstractions, not on the transport/model. | `AIService` protocol abstracts OpenRouter vs local MLX; `ModelRoutingAIService` routes, it does not implement. |

### 1.3 Design patterns — use them deliberately

Use the established patterns where they fit; do not invent parallel ones:

- **Coordinator** for orchestration (`ConversationSendCoordinator`, `LogCoordinator`).
- **Actor** for isolated state (`VectorStoreService`, `ConversationLogStore`, `AppLogger`).
- **Strategy** for swappable behavior (memory monitoring, repetition guidance).
- **Repository** for model/container lifetime (`MLXModelRepository`).
- **Registry** for pluggable units (`AIServiceRegistry`, `InferenceUnloadRegistry`, `ParserRegistry`).
- **Pub/Sub via EventBus** for decoupled notifications (typed `Event` conformers).

If a pattern is not listed here, prefer the simplest thing that works (KISS) and only
introduce the pattern when the code demands it.

## 2. Testing — TDD with red-green-refactor

We write tests first, in the red-green-refactor loop:

1. **Red** — write a failing test that expresses the behavior you want.
2. **Green** — write the minimal production code to make it pass.
3. **Refactor** — clean it up under the safety of the green test.

### 2.1 What to test

- **Unit tests** (`CompassTests/`) — pure logic, seams, policies: prompt building, budget,
  prefix-hash stability, repetition detection, pressure policy. Fast, no I/O.
- **Harness tests** (`CompassHarnessTests/`) — the real app container, real prompts, real
  tools, headless. This is an integration test of the live engine path; it does **not**
  mock or stub production logic.
- **UI-heavy suites** are skipped by `./run.sh test` (AppKit rendering); they are covered by
  harness/e2e instead.

### 2.2 Test rules

- A test that cannot fail is worse than no test — it costs maintenance and asserts nothing.
  (If you find one, delete it, e.g. `XCTAssertNotNil` on a struct.)
- Tests are written against seams (`EngineMemoryMonitoring`, `ConversationHistoryProviding`),
  never against the network or the MLX runtime.
- When you change behavior, the test changes first (red), then the code (green).
- If a change touches the agent loop, tools, prompts, or finalization, run the harness —
  "the agent gets tested by agents" (`CONTRIBUTING.md`).

## 3. DRY — single source of truth

- **One implementation per concern.** Never two competing implementations of the same
  thing (cardinal rule 4). If you find a duplicate, delete the dead one and route through
  the live one. Do not fix both paths.
- **One source of truth per fact.** Tool names live in `ToolTaxonomy`. Markup stripping
  lives in `ToolMarkupStripper`. Argument coercion lives in `ToolArgumentCoercion`. MLX
  cache policy lives in `NativeMLXGenerator`. If a value exists in two places, one of them
  is wrong.
- **Shared helpers are hoisted, not copied.** Identical logic (e.g. `commonPrefixLength`)
  exists once, as a shared helper — not once per file.

## 4. SRP — one responsibility, one place

- A type does one thing. If a file's doc comment needs "and" more than once, split it.
- The live path is the path. Dead seams, stub services, and "will take the logic in the
  next slice" scaffolding are SRP/YAGNI violations — delete them in the same change
  (AGENTS.md rule 1).

## 5. KISS — simplest thing that works

- Prefer the smallest change that satisfies the requirement. Do not add configurability,
  feature flags, or abstractions for scenarios that cannot happen.
- Do not design for hypothetical futures. When the future arrives, refactor then.
- Three similar lines are better than a premature abstraction. One-time operations do not
  need a helper.

## 6. YAGNI — you ain't gonna need it

- No speculative generality: no unused seams, no unused enum cases, no dead stored
  properties. If it has zero call sites, it is dead — delete it.
- No env vars without a consumer and documentation (see §8).
- The abandoned `MLXGenerationService`/`MLXKVCacheManager` seams were a YAGNI violation:
  introduced for a refactor that never happened, and one of them encoded a bug the live
  code had already fixed. The cost of speculative seams is real.

## 7. Static analysis — keep raising the bar

### 7.1 What we have today

- **SwiftLint** via `./run.sh lint` — advisory, runs the repo's `.swiftlint.yml`,
  including the `DESIGN_STANDARDS` guardrail (`hardcoded_corner_radius`).
- **`./run.sh check-prompts`** — guardrail: no orphan prompt files (no code reference).

### 7.2 What we are missing (journey, not destination)

| Tool | Status | Intended role |
|---|---|---|
| Code-duplication detector | **Missing** | Catch copy-pasted logic that DRY forbids (e.g. tokenizer bridges, prefix helpers) |
| Cyclomatic-complexity gate | **Missing** | Flag functions that have grown past reason; forces SRP decomposition |
| SwiftLint as CI gate | Advisory only | Promote from advisory to blocking on the hot path once the backlog is clean |
| Type-check / build as gate | **Present** | `./run.sh build` is the source of truth (sourcekit-lsp has false positives on cross-module types) |

When you add a tool, it must be **documented here** (what it enforces, how to run it, how
to opt out) and wired into `run.sh` — an undocumented check is not a standard.

## 8. Environment variables

Every `COMPASS_*` knob read in code must be:

1. Documented in one place (AGENTS.md env table or this doc), and
2. Have a consumer that actually uses it.

An env var with no consumer, or a consumer with no documentation, is debt — remove or
document it in the same change.

## 9. Enforcing the standard

- **In review:** call out violations by name (§1–§8) so the fix is unambiguous.
- **In PRs:** state what you verified (`./run.sh build`, `./run.sh test`, harness where
  applicable). A PR that cannot show green verification is not done.
- **In code:** when you touch a file, leave it better than you found it — but only within
  the scope of your change. Do not refactor unrelated code in the same PR.
- **On the journey:** if a rule is aspirational today, say so. The goal is steady progress
  toward fully green, not a one-time purge.

## 10. Relationship to other documents

| Document | Scope |
|---|---|
| `DESIGN_STANDARDS.md` | UI/UX tokens, spacing, idioms, guardrails |
| `AGENTS.md` | Engine live path, modes, harness, cardinal invariants |
| `.agents/skills/deepcode-cardinal-rules/SKILL.md` | The 5 non-negotiable process rules |
| `CONTRIBUTING.md` | PR/process norms |
| **This document** | Architecture, SOLID, TDD, DRY/SRP/KISS/YAGNI, static analysis |
