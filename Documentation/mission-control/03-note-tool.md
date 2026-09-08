# 03 — Note Tool & Working Memory

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Overview

The `note` tool is the model's interface to its own persistent working memory. After reading a file or receiving search results, the model calls `note()` to write a compact finding. Notes are stored in `WorkingMemoryStore` (actor, conversation-scoped, persisted to `.ide/working-memory/`) and rendered in Mission Control.

The key innovation is **intent tagging**: the model declares whether a read was for understanding (`finding`) or for editing (`edit_target`). This makes compression agent-aware — the system knows which raw reads can be safely evicted and which must be preserved.

---

## 2. NoteTool Specification

### 2.1 Tool Definition

```swift
struct NoteTool: AITool {
    let name = "note"
    let description = """
    Write a finding to your persistent working memory. Your notes survive \
    context resets — raw tool results do not. After reading a file or search \
    results, immediately write a compact note capturing what you learned.
    
    Use intent='finding' for code read to understand structure/behavior. \
    The raw read becomes disposable after noting — your note preserves the knowledge.
    
    Use intent='edit_target' for code you are about to edit. \
    The raw read is preserved through context resets until your edit completes.
    
    Your notes ARE your memory. If you don't note it, you lose it.
    """
    
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["add", "update", "clear"],
                    "description": "add: new finding. update: revise existing section. clear: remove a section."
                ],
                "section": [
                    "type": "string",
                    "description": "Section name. Use file names for file-specific findings (e.g., 'PaymentService'), 'architecture' for structural overview, 'risks' for issues, 'decisions' for choices made."
                ],
                "content": [
                    "type": "string",
                    "description": "Compact finding. 1-3 sentences. Include file:line references for later surgical re-reads. Note risks with (RISK) or (CRITICAL). Do not copy code — reference it by file:line."
                ],
                "intent": [
                    "type": "string",
                    "enum": ["finding", "edit_target"],
                    "description": "finding = read for understanding (raw read can be evicted after noting). edit_target = read for editing (raw read preserved through context resets). Defaults to finding."
                ]
            ],
            "required": ["action", "section", "content"]
        ]
    }
    
    let workingMemoryStore: WorkingMemoryStore
    let semanticCompressor: SemanticCompressor?
    
    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        let action = raw["action"] as? String ?? "add"
        let section = raw["section"] as? String ?? ""
        let content = raw["content"] as? String ?? ""
        let intent = NoteIntent(rawValue: raw["intent"] as? String ?? "finding") ?? .finding
        let conversationId = ToolInvocationContext.from(arguments: raw).conversationId ?? ""
        
        guard !conversationId.isEmpty else {
            return error("No conversation context.", code: "NO_CONTEXT")
        }
        guard !section.isEmpty else {
            return error("section is required.", code: "MISSING_SECTION")
        }
        guard !content.isEmpty else {
            return error("content is required.", code: "MISSING_CONTENT")
        }
        
        switch action {
        case "add":
            // Check for semantic duplication (NPU)
            if let compressor = semanticCompressor {
                let existing = await workingMemoryStore.allNoteTexts(conversationId: conversationId)
                if let duplicate = await compressor.findDuplicateNote(
                    newNote: content,
                    existingNotes: existing
                ) {
                    return """
                    status: duplicate
                    message: "This note appears to duplicate an existing finding: '\(duplicate.prefix(100))...'
                    Use action='update' to revise the existing section instead."
                    content:
                      action: "add"
                      duplicate: true
                    """
                }
            }
            
            let note = WorkingMemoryNote(
                id: UUID().uuidString,
                section: section,
                content: content,
                intent: intent,
                timestamp: Date()
            )
            await workingMemoryStore.add(conversationId: conversationId, note: note)
            return successResponse(action: "add", section: section, noteCount: await workingMemoryStore.noteCount(conversationId: conversationId))
            
        case "update":
            await workingMemoryStore.updateSection(
                conversationId: conversationId,
                section: section,
                content: content,
                intent: intent
            )
            return successResponse(action: "update", section: section, noteCount: await workingMemoryStore.noteCount(conversationId: conversationId))
            
        case "clear":
            await workingMemoryStore.clearSection(conversationId: conversationId, section: section)
            return successResponse(action: "clear", section: section, noteCount: await workingMemoryStore.noteCount(conversationId: conversationId))
            
        default:
            return error("action must be 'add', 'update', or 'clear'.", code: "INVALID_ACTION")
        }
    }
    
    private func successResponse(action: String, section: String, noteCount: Int) -> String {
        """
        status: success
        message: "Note \(action)ed in section '\(section)'. \(noteCount) note(s) in working memory."
        content:
          action: "\(action)"
          section: "\(section)"
          total_notes: \(noteCount)
        """
    }
    
    private func error(_ message: String, code: String) -> String {
        """
        status: error
        message: "\(message)"
        error:
          code: \(code)
          recoverable: true
        """
    }
}
```

### 2.2 Tool Registration

Add to `ConversationToolProvider.allTools()`:

```swift
// Working Memory — the model's persistent notebook
let workingMemoryStore = WorkingMemoryStore.shared  // or injected
let semanticCompressor = SemanticCompressor(embedder: embedder, vectorStore: vectorStoreService)
tools.append(NoteTool(workingMemoryStore: workingMemoryStore, semanticCompressor: semanticCompressor))
```

Add to `ToolTaxonomy`:

```swift
static let memory: Set<String> = ["note"]

// Update execution set
static let execution: Set<String> = readOnly.union(mutation).union(terminal).union(["context", "plan", "note"])
```

The `note` tool is available in **all agentic modes** (coder, agent). It is NOT available in chat mode (chat is read-only co-pilot — no persistent working memory needed for Q&A).

Update `AIMode.allowedTools`:
```swift
case .chat:
    let blocked = ToolTaxonomy.mutation.union(ToolTaxonomy.terminal).union(ToolTaxonomy.planning).union(ToolTaxonomy.memory)
    return allTools.filter { !blocked.contains($0.name) }
case .coder, .agent:
    return allTools  // note is included
```

### 2.3 Prompt for the Tool

Create `Prompts/Tools/v3/note.md`:

```markdown
## note — Working Memory

### WHAT
Write a finding to your persistent working memory. Notes survive context resets; raw tool results do not.

### WHEN
- After EVERY `read` call — capture what you learned
- After `search` results that reveal structure — capture the key findings
- After `bash` output that reveals build/test status — capture the result
- Before a context reset — ensure all critical findings are noted
- NOT for code you're about to edit (use intent='edit_target' instead)

### HOW
- action: "add" (new note), "update" (revise section), "clear" (remove section)
- section: Use file names for file-specific findings, "architecture" for structure, "risks" for issues, "decisions" for choices
- content: 1-3 sentences. Include file:line references. Note risks with (RISK) or (CRITICAL). Do NOT copy code.
- intent: "finding" (read to understand — raw read disposable) or "edit_target" (read to edit — raw read preserved)

### OUTPUT
status: success | duplicate | error
message: confirmation with note count
```

Add `"Tools/v3/note"` to the `toolPromptKeys` array in `SystemPromptAssembler`.

---

## 3. WorkingMemoryStore Specification

### 3.1 Data Structures

```swift
/// Intent declared by the model when writing a note.
/// Controls whether the raw tool result is evictable.
enum NoteIntent: String, Codable, Sendable {
    case finding        // read for understanding — raw read disposable after noting
    case editTarget     // read for editing — raw read preserved through resets
}

/// A single note in working memory.
struct WorkingMemoryNote: Codable, Sendable, Identifiable {
    let id: String
    let section: String          // e.g., "PaymentService", "architecture", "risks"
    let content: String          // compact finding, 1-3 sentences
    let intent: NoteIntent
    let timestamp: Date
    var associatedToolCallId: String?  // links to the tool result this note summarizes
}

/// A snapshot of working memory for a conversation.
struct WorkingMemorySnapshot: Codable, Sendable {
    var notes: [WorkingMemoryNote] = []
    var lastResetAt: Date?       // when the last controlled reset happened
    
    var isEmpty: Bool { notes.isEmpty }
    
    func notesBySection() -> [String: [WorkingMemoryNote]] {
        Dictionary(grouping: notes) { $0.section }
    }
    
    func editTargetSections() -> Set<String> {
        Set(notes.filter { $0.intent == .editTarget }.map { $0.section })
    }
    
    func renderForContext() -> String {
        let grouped = notesBySection()
            .sorted { $0.key < $1.key }  // NPU clustering can override this ordering
        
        var lines: [String] = []
        for (section, sectionNotes) in grouped {
            lines.append("**\(section):**")
            for note in sectionNotes {
                lines.append(note.content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
```

### 3.2 The Store

```swift
/// Conversation-scoped persistent working memory.
/// Actor for thread safety (matches VectorStoreService, ConversationLogStore patterns).
actor WorkingMemoryStore {
    static let shared = WorkingMemoryStore()
    
    private var snapshots: [String: WorkingMemorySnapshot] = [:]
    private var projectRoot: URL?
    private let maxNotesPerConversation = 50  // hard cap; oldest evicted
    
    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }
    
    func get(conversationId: String) -> WorkingMemorySnapshot {
        if let cached = snapshots[conversationId] {
            return cached
        }
        // Load from disk
        guard let url = fileURL(conversationId: conversationId),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WorkingMemorySnapshot.self, from: data) else {
            return WorkingMemorySnapshot()
        }
        snapshots[conversationId] = snapshot
        return snapshot
    }
    
    func add(conversationId: String, note: WorkingMemoryNote) {
        var snapshot = get(conversationId: conversationId)
        snapshot.notes.append(note)
        enforceMaxNotes(&snapshot)
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }
    
    func updateSection(conversationId: String, section: String, content: String, intent: NoteIntent) {
        var snapshot = get(conversationId: conversationId)
        // Remove existing notes in this section, add the updated one
        snapshot.notes.removeAll { $0.section == section }
        snapshot.notes.append(WorkingMemoryNote(
            id: UUID().uuidString,
            section: section,
            content: content,
            intent: intent,
            timestamp: Date()
        ))
        enforceMaxNotes(&snapshot)
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }
    
    func clearSection(conversationId: String, section: String) {
        var snapshot = get(conversationId: conversationId)
        snapshot.notes.removeAll { $0.section == section }
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }
    
    func clear(conversationId: String) {
        snapshots.removeValue(forKey: conversationId)
        if let url = fileURL(conversationId: conversationId) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func markReset(conversationId: String) {
        var snapshot = get(conversationId: conversationId)
        snapshot.lastResetAt = Date()
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }
    
    func noteCount(conversationId: String) -> Int {
        get(conversationId: conversationId).notes.count
    }
    
    func allNoteTexts(conversationId: String) -> [String] {
        get(conversationId: conversationId).notes.map { $0.content }
    }
    
    func editTargetSections(conversationId: String) -> Set<String> {
        get(conversationId: conversationId).editTargetSections()
    }
    
    // MARK: - Private
    
    private func enforceMaxNotes(_ snapshot: inout WorkingMemorySnapshot) {
        guard snapshot.notes.count > maxNotesPerConversation else { return }
        // Evict oldest finding notes first; keep edit_target notes
        let findingNotes = snapshot.notes.filter { $0.intent == .finding }
            .sorted { $0.timestamp < $1.timestamp }
        let toEvict = max(0, snapshot.notes.count - maxNotesPerConversation)
        let evictIds = Set(findingNotes.prefix(toEvict).map { $0.id })
        snapshot.notes.removeAll { evictIds.contains($0.id) }
    }
    
    private func fileURL(conversationId: String) -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("working-memory", isDirectory: true)
            .appendingPathComponent("\(conversationId).json")
    }
    
    private func persist(conversationId: String, snapshot: WorkingMemorySnapshot) {
        guard let url = fileURL(conversationId: conversationId) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
```

### 3.3 File System Layout

```
.ide/
├── working-memory/                    # NEW
│   ├── {conversationId-1}.json        # WorkingMemorySnapshot
│   ├── {conversationId-2}.json
│   └── ...
├── plans/                             # EXISTING
│   └── {conversationId}.json
├── vector_store/                      # EXISTING (FAISS)
└── ...
```

---

## 4. Intent Tagging — How It Affects Eviction

### 4.1 The Intent Lifecycle

```
Model reads PaymentService.php (intent: understand)
  → Model calls note(section="PaymentService", intent="finding", content="...")
  → System marks the tool result for PaymentService.php as "noted with finding intent"
  → Tool result is now ELIGIBLE for eviction (knowledge preserved in note)

Model reads checkout.js (intent: edit)
  → Model calls note(section="checkout.js", intent="edit_target", content="...")
  → System marks the tool result for checkout.js as "noted with edit_target intent"
  → Tool result is PROTECTED — preserved through context resets

Model edits checkout.js
  → Model calls edit(path="checkout.js", ...)
  → Edit succeeds
  → System marks the checkout.js tool result as "edit complete"
  → Tool result is now ELIGIBLE for eviction (edit is done, note has the summary)
```

### 4.2 Tracking Tool Result → Note Association

When the model calls `note()`, the system correlates the note with the most recent un-noted tool result:

```swift
// In NoteTool.execute(), when creating the note:
let lastUnnotedToolCallId = await toolResultNoteTracker.lastUnnotedToolCallId(
    conversationId: conversationId
)
let note = WorkingMemoryNote(
    id: UUID().uuidString,
    section: section,
    content: content,
    intent: intent,
    timestamp: Date(),
    associatedToolCallId: lastUnnotedToolCallId
)
```

`ToolResultNoteTracker` (simple actor) maintains a map of `toolCallId → noted: Bool` and `toolCallId → intent: NoteIntent`. This lets the eviction logic know which tool results are safe to evict.

### 4.3 ToolResultNoteTracker

```swift
actor ToolResultNoteTracker {
    private var toolCallStatus: [String: (noted: Bool, intent: NoteIntent?)] = [:]
    
    func recordToolResult(toolCallId: String, conversationId: String) {
        toolCallStatus[toolCallId] = (noted: false, intent: nil)
    }
    
    func markNoted(toolCallId: String, intent: NoteIntent) {
        toolCallStatus[toolCallId] = (noted: true, intent: intent)
    }
    
    func isEvictable(toolCallId: String) -> Bool {
        guard let status = toolCallStatus[toolCallId] else { return true } // untracked = evictable
        if !status.noted { return false } // not yet noted — keep until noted
        if status.intent == .editTarget { return false } // edit target — protected
        return true // finding — evictable
    }
    
    func markEditComplete(toolCallId: String) {
        // After edit completes, the edit_target read becomes evictable
        if var status = toolCallStatus[toolCallId] {
            status = (noted: true, intent: .finding) // downgrade to finding
            toolCallStatus[toolCallId] = status
        }
    }
    
    func lastUnnotedToolCallId(conversationId: String) -> String? {
        // Return the most recent toolCallId that hasn't been noted yet
        // Used by NoteTool to associate notes with tool results
        toolCallStatus
            .filter { !$0.value.noted }
            .keys
            .max() // simplistic — in practice, track order
    }
    
    func clear(conversationId: String) {
        toolCallStatus.removeAll()
    }
}
```

---

## 5. Integration with Existing Plan Tool

The `note` tool complements the existing `plan` tool — they serve different purposes:

| Tool | Purpose | What it stores | When model calls it |
|---|---|---|---|
| `plan` | Task decomposition and progress | `TaskPlan` (goal, items, status) | Start of task, when task completes |
| `note` | Working memory and findings | `WorkingMemorySnapshot` (notes by section) | After every read/search, when discovering something |

**They do not overlap.** The plan is the *what* (tasks to do). Notes are the *what I learned* (findings from exploration). Mission Control renders both together.

### 5.1 Plan Item Completion via Notes

When the model completes a plan item, it should note the outcome:

```
Model: plan(action: "finishTask", summary: "Reviewed PaymentService — found hardcoded key and no validation")
Model: note(section="PaymentService", intent="finding", content="Review complete: hardcoded Stripe key (CRITICAL), no amount validation (RISK)")
```

The `plan` call advances the task. The `note` call preserves the findings. Both feed into Mission Control.

---

## 6. Edge Cases

### 6.1 Model doesn't take notes

If the model explores without calling `note()`, tool results are not marked as "noted" and are kept in the working set longer (until standard eviction kicks in). The prompt strongly encourages noting, but it's not enforced — the model might choose not to note low-value reads. This is acceptable: the model is the decision-maker.

### 6.2 Model notes the same thing twice

The NPU `findDuplicateNote()` check catches this. The model gets a `status: duplicate` response and is told to use `action: "update"` instead. This prevents note bloat.

### 6.3 Model calls note with edit_target but never edits

The `edit_target` read stays protected indefinitely. This is a minor inefficiency (one extra tool result in context) but not a correctness issue. The model can call `note(action: "update", intent: "finding")` to downgrade the intent if it decides not to edit after all.

### 6.4 Working memory grows too large

The `maxNotesPerConversation = 50` cap evicts oldest `finding` notes first, keeping `edit_target` notes. Evicted notes remain in FAISS (retrievable via `context()` tool). Mission Control rendering also has a 15-note display cap (see [02-mission-control.md](02-mission-control.md)).

### 6.5 New conversation / session restore

`WorkingMemoryStore` loads from disk on first access for a conversation ID. When a conversation is restored (session switch), the working memory is restored with it. Notes persist across app restarts.

### 6.6 Conversation cleared

When `ChatHistoryCoordinator.clear()` is called, `WorkingMemoryStore.clear(conversationId:)` should also be called to clean up the working memory file. This is wired in `ConversationManager` alongside the existing history clear.
