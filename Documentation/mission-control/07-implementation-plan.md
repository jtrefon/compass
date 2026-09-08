# 07 — Implementation Plan

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Phased Rollout

Four phases. Each phase is independently shippable and testable. No big-bang deployment.

### Phase 1: Foundation (Note Tool + Working Memory + Mission Control)

**Goal:** The model can take notes and see them in Mission Control. No eviction changes, no NPU, no reset logic. Just the notebook + the display.

**Deliverables:**
- `WorkingMemoryStore` actor with persistence
- `NoteTool` with intent tagging
- `ToolResultNoteTracker` actor
- `MissionControlBuilder` (Goal + Plan + Working Memory + Budget sections only — no Key Excerpts yet)
- Mission Control injection in `LocalModelToolLoop` and `AgentLoop`
- `context-discipline.md` prompt
- `note.md` tool prompt
- `mode-coder.md` and `mode-agent.md` prompt updates
- `SystemPromptAssembler` integration
- `ConversationToolProvider` registration
- `ToolTaxonomy` update (add `memory` set, add `note` to `execution`)

**Files created (8):**
| File | Purpose |
|---|---|
| `Compass/Services/WorkingMemory/WorkingMemoryStore.swift` | Persistent note storage actor |
| `Compass/Services/WorkingMemory/WorkingMemoryModels.swift` | `WorkingMemoryNote`, `WorkingMemorySnapshot`, `NoteIntent` |
| `Compass/Services/WorkingMemory/ToolResultNoteTracker.swift` | Tool result → note association tracker |
| `Compass/Services/Tools/NoteTool.swift` | The `note` tool implementation |
| `Compass/Services/MissionControl/MissionControlBuilder.swift` | Builds the Mission Control block |
| `Prompts/System/context-discipline.md` | Context discipline prompt |
| `Prompts/Tools/v3/note.md` | Note tool prompt |
| `CompassTests/WorkingMemoryTests.swift` | Unit tests for WorkingMemoryStore + NoteTool |

**Files modified (5):**
| File | Change |
|---|---|
| `Compass/Services/ConversationToolProvider.swift` | Register `NoteTool` |
| `Compass/Services/Tools/ToolTaxonomy.swift` | Add `memory` set, add `note` to `execution` |
| `Compass/Services/LocalModels/LocalModelToolLoop.swift` | Inject Mission Control as last user message |
| `Compass/Services/Orchestration/AgentLoop.swift` | Inject Mission Control as last user message |
| `Compass/Services/SystemPromptAssembler.swift` (or equivalent) | Add `context-discipline.md` and `note.md` to assembly |

**Files modified (prompts) (2):**
| File | Change |
|---|---|
| `Prompts/System/mode-coder.md` | Add `note` to tools, add context discipline section, update research discipline |
| `Prompts/System/mode-agent.md` | Same changes as mode-coder.md |

**Verification:**
```bash
./run.sh build
./run.sh test WorkingMemoryTests
./run.sh check-prompts
./run.sh harness PureAgenticHarnessTests
```

**Success criteria:**
- Model takes notes after reads (observable in telemetry)
- Mission Control appears in conversation history as last user message
- Notes persist to `.ide/working-memory/`
- `check-prompts` passes (no orphan files)
- Existing harness tests still pass (no regression)

---

### Phase 2: NPU Semantic Intelligence

**Goal:** The NPU compresses tool results and selects key excerpts. Notes are deduplicated. Mission Control gets Key Excerpts section.

**Deliverables:**
- `SemanticCompressor` actor
- Extractive compression (chunking, embedding, scoring, top-K selection)
- Semantic deduplication for notes
- Key Excerpts section in Mission Control
- FAISS storage of tool result chunks
- Language-aware chunking (Swift, PHP, JS, TS, Python, etc.)
- NPU-unavailable graceful degradation

**Files created (3):**
| File | Purpose |
|---|---|
| `Compass/Services/MissionControl/SemanticCompressor.swift` | NPU semantic intelligence actor |
| `Compass/Services/MissionControl/SemanticChunking.swift` | Language-aware chunking utilities |
| `CompassTests/SemanticCompressorTests.swift` | Unit tests for compression, dedup, chunking |

**Files modified (2):**
| File | Change |
|---|---|
| `Compass/Services/MissionControl/MissionControlBuilder.swift` | Add Key Excerpts section, use `SemanticCompressor` for note clustering |
| `Compass/Services/Tools/NoteTool.swift` | Wire up `findDuplicateNote()` check |

**Verification:**
```bash
./run.sh build
./run.sh test SemanticCompressorTests
./run.sh test WorkingMemoryTests
COMPASS_CONFIG=Release ./run.sh benchmark-local  # NPU perf in Release
./run.sh harness PureAgenticHarnessTests
```

**Success criteria:**
- Key Excerpts appear in Mission Control (relevant code chunks)
- Duplicate notes are rejected with `status: duplicate`
- NPU runs in parallel with LLM (no generation latency increase)
- FAISS stores tool result chunks (verifiable via `context()` tool)
- NPU-unavailable fallback works (no crash if embedding model missing)

---

### Phase 3: Controlled Reset (Local Path)

**Goal:** Replace progressive system-prompt truncation with intentional controlled resets. Fix `preservesCache` bug. Implement note-aware eviction.

**Deliverables:**
- `performControlledReset()` in `LocalModelToolLoop`
- `ChatHistoryCoordinator.replaceWithReset()` method
- `budgetMessages` replacement (compute-only, no truncation)
- `preservesCache: true` fix in `LocalModelToolLoop`
- Reset telemetry logging
- Smart retrieval from FAISS during reset (using `SemanticCompressor.scoreForRetrieval()`)
- Note-aware eviction (finding-tagged results evicted, edit_target preserved)

**Files modified (4):**
| File | Change |
|---|---|
| `Compass/Services/LocalModels/LocalModelToolLoop.swift` | Add reset trigger + `performControlledReset()`, fix `preservesCache` |
| `Compass/Services/ChatHistoryCoordinator.swift` | Add `replaceWithReset()` method |
| `Compass/Services/LocalModels/LocalModelPromptBuilder.swift` | Replace `budgetMessages` with `computeBudget` (no truncation) |
| `Compass/Services/MissionControl/MissionControlBuilder.swift` | Add `computeBudget()` method for reset trigger |

**Files created (1):**
| File | Purpose |
|---|---|
| `CompassTests/ControlledResetTests.swift` | Tests for reset procedure, KV cache, edit_target preservation |

**Verification:**
```bash
./run.sh build
./run.sh test ControlledResetTests
./run.sh test WorkingMemoryTests
COMPASS_CONFIG=Release ./run.sh benchmark-local  # KV cache KPI in Release
./run.sh harness PureAgenticHarnessTests
```

**Success criteria:**
- System prompt is NEVER truncated (always full instructions)
- Controlled reset fires at 75% context usage
- Reset preserves Mission Control, edit_targets, recent results
- Reset evicts finding-tagged results (knowledge in notes)
- KV cache is invalidated only during reset (not every turn)
- Benchmark shows fewer prefills per task (vs current)
- Model continues effectively after reset (no memory loss)

---

### Phase 4: Cloud Path Parity + Polish

**Goal:** Note-aware eviction for cloud path. Information density scoring. Note clustering in Mission Control rendering. Final polish and telemetry.

**Deliverables:**
- `PipelineProcessor.prepareForRequestNoteAware()`
- Note-aware eviction in cloud `AgentLoop`
- Information density scoring in Mission Control
- Note clustering in Mission Control rendering
- Comprehensive telemetry dashboard
- Documentation finalization

**Files modified (3):**
| File | Change |
|---|---|
| `Compass/Services/CloudPipeline/PipelineProcessor.swift` | Add `prepareForRequestNoteAware()` |
| `Compass/Services/Orchestration/AgentLoop.swift` | Use note-aware eviction, drop old MC messages |
| `Compass/Services/MissionControl/MissionControlBuilder.swift` | Add information density, note clustering |

**Files created (1):**
| File | Purpose |
|---|---|
| `CompassTests/NoteAwareEvictionTests.swift` | Tests for cloud eviction priority |

**Verification:**
```bash
./run.sh build
./run.sh test NoteAwareEvictionTests
./run.sh test  # full suite
./run.sh harness
COMPASS_CONFIG=Release ./run.sh benchmark-local
./run.sh check-prompts
```

**Success criteria:**
- Cloud path evicts finding-tagged results first
- Cloud path preserves edit_targets and recent results
- Old Mission Control messages are dropped (not re-sent)
- Information density score appears in Mission Control
- Notes are clustered by semantic similarity in rendering
- All tests pass
- All harness suites pass
- Token usage reduced vs baseline (measurable in telemetry)

---

## 2. Testing Strategy

### 2.1 Unit Tests

| Test Suite | Phase | What it tests |
|---|---|---|
| `WorkingMemoryTests` | 1 | Note CRUD, persistence, intent tagging, max notes eviction, session restore |
| `SemanticCompressorTests` | 2 | Chunking (per language), embedding, scoring, top-K selection, dedup, clustering |
| `ControlledResetTests` | 3 | Reset procedure, edit_target preservation, finding eviction, KV cache behavior |
| `NoteAwareEvictionTests` | 4 | Cloud eviction priority, pair-safe guard, budget compliance |

### 2.2 Unit Test Examples

**WorkingMemoryTests:**
```swift
@MainActor
final class WorkingMemoryTests: XCTestCase {
    
    func testNoteAddAndRetrieve() async throws {
        let store = WorkingMemoryStore.shared
        store.setProjectRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
        let conversationId = "test-\(UUID().uuidString)"
        
        let note = WorkingMemoryNote(
            id: UUID().uuidString,
            section: "PaymentService",
            content: "Hardcoded Stripe key (CRITICAL)",
            intent: .finding,
            timestamp: Date()
        )
        await store.add(conversationId: conversationId, note: note)
        
        let snapshot = await store.get(conversationId: conversationId)
        XCTAssertEqual(snapshot.notes.count, 1)
        XCTAssertEqual(snapshot.notes[0].section, "PaymentService")
        XCTAssertEqual(snapshot.notes[0].intent, .finding)
        
        await store.clear(conversationId: conversationId)
    }
    
    func testMaxNotesEviction() async throws {
        let store = WorkingMemoryStore.shared
        store.setProjectRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
        let conversationId = "test-\(UUID().uuidString)"
        
        // Add 55 notes (max is 50)
        for i in 0..<55 {
            let note = WorkingMemoryNote(
                id: UUID().uuidString,
                section: "section\(i)",
                content: "Finding \(i)",
                intent: .finding,
                timestamp: Date().addingTimeInterval(TimeInterval(i))
            )
            await store.add(conversationId: conversationId, note: note)
        }
        
        let snapshot = await store.get(conversationId: conversationId)
        XCTAssertEqual(snapshot.notes.count, 50)
        // Oldest finding notes should be evicted (findings 0-4)
        let sections = snapshot.notes.map { $0.section }
        XCTAssertFalse(sections.contains("section0"))
        XCTAssertFalse(sections.contains("section4"))
        XCTAssertTrue(sections.contains("section5"))
        
        await store.clear(conversationId: conversationId)
    }
    
    func testEditTargetPreservedDuringEviction() async throws {
        let store = WorkingMemoryStore.shared
        store.setProjectRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
        let conversationId = "test-\(UUID().uuidString)"
        
        // Add 50 finding notes (at max)
        for i in 0..<50 {
            let note = WorkingMemoryNote(
                id: UUID().uuidString,
                section: "finding\(i)",
                content: "Finding \(i)",
                intent: .finding,
                timestamp: Date().addingTimeInterval(TimeInterval(i))
            )
            await store.add(conversationId: conversationId, note: note)
        }
        
        // Add an edit_target note (should be preserved even when over max)
        let editNote = WorkingMemoryNote(
            id: UUID().uuidString,
            section: "checkout.js",
            content: "Need to add validation at L23",
            intent: .editTarget,
            timestamp: Date()
        )
        await store.add(conversationId: conversationId, note: editNote)
        
        let snapshot = await store.get(conversationId: conversationId)
        XCTAssertEqual(snapshot.notes.count, 50)
        let sections = snapshot.notes.map { $0.section }
        XCTAssertTrue(sections.contains("checkout.js"), "edit_target should be preserved")
        
        await store.clear(conversationId: conversationId)
    }
    
    func testPersistenceAcrossSessions() async throws {
        let store = WorkingMemoryStore.shared
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"
        
        let note = WorkingMemoryNote(
            id: UUID().uuidString,
            section: "TestSection",
            content: "Test finding",
            intent: .finding,
            timestamp: Date()
        )
        await store.add(conversationId: conversationId, note: note)
        
        // Create a new store instance (simulates app restart)
        let newStore = WorkingMemoryStore()
        newStore.setProjectRoot(tempDir)
        let snapshot = await newStore.get(conversationId: conversationId)
        XCTAssertEqual(snapshot.notes.count, 1)
        XCTAssertEqual(snapshot.notes[0].content, "Test finding")
        
        await store.clear(conversationId: conversationId)
    }
}
```

### 2.3 Harness Tests

| Harness Suite | Phase | What it validates |
|---|---|---|
| `PureAgenticHarnessTests` | 1-4 | No regression in basic agentic flow |
| `MissionControlHarnessTests` (new) | 1 | Model takes notes, Mission Control appears in history |
| `ContextResetHarnessTests` (new) | 3 | Model continues after reset, no memory loss |
| `WordPressReviewReproductionTests` | 4 | WordPress review completes within context budget |

### 2.4 Benchmark Comparisons

Run `COMPASS_CONFIG=Release ./run.sh benchmark-local` before and after each phase:

| Metric | Baseline | Target |
|---|---|---|
| Tokens consumed for WordPress review | ~40K | < 15K |
| Prefills per 15-turn task | 10+ | 2-3 |
| Decode throughput (t/s) | 23.6 | 23.6 (no change — NPU doesn't affect GPU) |
| Context resets per task | 0 (current: progressive truncation) | 1-2 (controlled) |
| Note-taking rate | N/A | > 80% of reads followed by notes |

---

## 3. Migration Path

### 3.1 No Breaking Changes

The Mission Control system is additive — it doesn't change existing tool behavior, file formats, or API contracts. Existing conversations continue to work:

- Old conversations (no notes): Mission Control shows "No notes yet" — model is prompted to start noting
- Old tool results: Not tracked by `ToolResultNoteTracker` — treated as evictable (no intent declared)
- Old plans: Rendered in Mission Control as-is
- Old FAISS entries: Still retrievable via `context()` tool

### 3.2 Feature Flag

The entire system can be gated behind `COMPASS_ENABLE_MISSION_CONTROL=1` for safe rollout:

```swift
// In ConversationToolProvider:
if ProcessInfo.processInfo.environment["COMPASS_ENABLE_MISSION_CONTROL"] == "1" {
    tools.append(NoteTool(workingMemoryStore: workingMemoryStore, semanticCompressor: semanticCompressor))
}

// In LocalModelToolLoop:
if ProcessInfo.processInfo.environment["COMPASS_ENABLE_MISSION_CONTROL"] == "1" {
    let missionControl = await missionControlBuilder.build(...)
    await history.append(ChatMessage(role: .user, content: missionControl))
}
```

This allows:
- Phase 1: Enable for internal testing
- Phase 2-3: Enable for beta users
- Phase 4: Enable by default, remove the flag

### 3.3 Cleanup After Rollout

Once Mission Control is enabled by default and stable:

1. Remove `COMPASS_ENABLE_MISSION_CONTROL` flag
2. Remove old `budgetMessages` truncation logic (replaced by `computeBudget`)
3. Remove `LocalModelIterationGuide` (replaced by Mission Control budget guidance)
4. Update `AGENTS.md` with Mission Control architecture
5. Archive old context-management documentation

---

## 4. Telemetry and KPIs

### 4.1 Telemetry Events

| Event | When | Data |
|---|---|---|
| `mission_control.injected` | Every turn MC is injected | conversationId, tokenCount, section sizes |
| `note.added` | Model calls note() | conversationId, section, intent, content length |
| `note.duplicate_rejected` | Dedup catches duplicate | conversationId, similarity score |
| `mission_control.reset` | Controlled reset fires | conversationId, prevCount, freshCount, tokensSaved |
| `semantic.chunk_processed` | NPU processes tool result | conversationId, chunkCount, topK, latency |
| `semantic.retrieval_scored` | NPU scores FAISS for reset | conversationId, candidateCount, topScore |

### 4.2 KPIs

| KPI | Measurement | Target |
|---|---|---|
| Context efficiency | Tokens consumed per task | 50% reduction vs baseline |
| Reset frequency | Resets per 15-turn task | 1-2 (vs 10+ truncations currently) |
| Note-taking rate | Notes / reads ratio | > 80% |
| Note quality | Information density | > 70% unique |
| KV cache stability | Prefills per task | 2-3 (vs 10+) |
| Model continuity | Tasks completed after reset | 100% (no abandoned tasks) |
| NPU overhead | Latency added per turn | < 125ms (invisible vs 2-3s LLM) |

---

## 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Model doesn't take notes | Medium | High (system fails) | Strong prompt, A/B test prompt variations, telemetry on note rate |
| NPU unavailable on some Macs | Low | Medium | Graceful degradation — system works without NPU (no compression, no dedup) |
| Reset loses critical context | Low | High | edit_target preservation, FAISS retrieval, telemetry on post-reset task completion |
| Mission Control too large | Medium | Medium | Size budget enforcement (3K tokens max), 15-note display cap |
| FAISS corruption | Low | High | Notes are in separate JSON files (not FAISS); FAISS is cold storage only |
| Prompt token budget exceeded | Low | Low | check-prompts validation, system prompt size monitoring |

---

## 6. Open Questions

| Question | Status | Decision needed by |
|---|---|---|
| Should Mission Control be injected in chat mode? | Open | Phase 1 — currently no (chat is Q&A, no persistent memory needed) |
| Should note tool be available in chat mode? | Open | Phase 1 — currently no (chat is read-only) |
| What is the optimal reset threshold? | Open | Phase 3 — start at 75%, tune based on telemetry |
| Should we support multiple working memory files per conversation? | Open | Phase 4 — currently one file per conversation |
| Should notes be editable by the user (UI)? | Future | Post-rollout — consider a notes panel in the UI |
| Should we compress Mission Control itself when it's too large? | Open | Phase 4 — currently hard-capped at 15 notes |
| Should the NPU run during streaming or only between turns? | Open | Phase 2 — currently between turns (detached task) |

---

## 7. Documentation Index

| Document | Title |
|---|---|
| [00-overview.md](00-overview.md) | Overview — Problem statement, architecture summary, design principles |
| [01-architecture.md](01-architecture.md) | Three-Tier Memory Architecture — Protected/Working/Cold, data flow, KV cache |
| [02-mission-control.md](02-mission-control.md) | Mission Control Block — Structure, injection, rendering, size budget |
| [03-note-tool.md](03-note-tool.md) | Note Tool & Working Memory — NoteTool spec, WorkingMemoryStore, intent tagging |
| [04-npu-semantic-layer.md](04-npu-semantic-layer.md) | NPU Semantic Intelligence — SemanticCompressor, compression, dedup, retrieval |
| [05-eviction-and-reset.md](05-eviction-and-reset.md) | Eviction & Controlled Reset — Note-aware eviction, reset procedure, KV handling |
| [06-prompt-engineering.md](06-prompt-engineering.md) | Prompt Engineering — Context discipline prompt, mode changes, tool prompt |
| [07-implementation-plan.md](07-implementation-plan.md) | Implementation Plan — Phased rollout, file list, testing, migration (this file) |

---

## 8. Summary

**Mission Control turns the context constraint from a weakness into a structural advantage.** Instead of passively filling up and breaking, the agent actively manages its own memory:

1. **The model takes notes** via the `note` tool — compact findings that survive context resets
2. **The NPU compresses tool results** in parallel with LLM generation — zero token cost, zero GPU contention
3. **Mission Control keeps the agent oriented** — goal, plan, notes, excerpts, and budget visible every turn
4. **Controlled resets replace progressive truncation** — one intentional prefill vs death by a thousand cuts
5. **Cold storage preserves everything** — FAISS makes all evicted content retrievable on demand

The result: an agent that thinks like an expert with a notebook, not a goldfish with a perfect memory of everything it's ever seen.
