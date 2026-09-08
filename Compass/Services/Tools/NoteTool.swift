import Foundation

/// The `note` tool — the model's interface to its own persistent working memory.
///
/// After reading a file or receiving search results, the model calls `note()`
/// to write a compact finding. Notes are stored in `WorkingMemoryStore`
/// (actor, conversation-scoped, persisted to `.ide/working-memory/`) and
/// rendered in Mission Control.
///
/// Intent tagging (`finding` vs `edit_target`) makes compression agent-aware:
/// - `finding` — code read to understand → raw read becomes disposable after noting
/// - `edit_target` — code read for editing → raw read is preserved through context resets
struct NoteTool: AITool {
    let name = "note"
    let description = """
    Write a finding to your persistent working memory. Your notes survive \
    context resets — raw tool results do not. After reading a file or search \
    results, immediately write a compact note capturing what you learned. \
    Your notes ARE your memory — if you don't note it, you lose it on reset.
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
                    "description": "finding = read for understanding (raw read disposable after noting). edit_target = read for editing (raw read preserved through context resets). Defaults to finding."
                ]
            ],
            "required": ["action", "section", "content"]
        ]
    }

    let workingMemoryStore: WorkingMemoryStore
    let noteTracker: ToolResultNoteTracker?
    let semanticCompressor: SemanticCompressor?

    init(
        workingMemoryStore: WorkingMemoryStore = .shared,
        noteTracker: ToolResultNoteTracker? = nil,
        semanticCompressor: SemanticCompressor? = nil
    ) {
        self.workingMemoryStore = workingMemoryStore
        self.noteTracker = noteTracker
        self.semanticCompressor = semanticCompressor
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        let action = raw["action"] as? String ?? "add"
        let section = (raw["section"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (raw["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = NoteIntent(rawValue: raw["intent"] as? String ?? "finding") ?? .finding
        let conversationId = ToolInvocationContext.from(arguments: raw).conversationId ?? ""

        guard !conversationId.isEmpty else {
            return errorResponse("No conversation context.", code: "NO_CONTEXT")
        }
        guard !section.isEmpty else {
            return errorResponse("section is required.", code: "MISSING_SECTION")
        }
        guard !content.isEmpty else {
            return errorResponse("content is required.", code: "MISSING_CONTENT")
        }

        switch action {
        case "add":
            // Check for semantic duplication (NPU) if available
            if let compressor = semanticCompressor {
                let existing = await workingMemoryStore.allNoteTexts(conversationId: conversationId)
                if let duplicate = await compressor.findDuplicateNote(
                    newNote: content,
                    existingNotes: existing
                ) {
                    return """
                    status: duplicate
                    message: "This note appears to duplicate an existing finding: '\(String(duplicate.prefix(100)))...'. Use action='update' to revise the existing section instead."
                    content:
                      action: "add"
                      duplicate: true
                    """
                }
            }

            // Associate with the most recent un-noted tool result
            let associatedToolCallId: String? = await MainActor.run {
                noteTracker?.lastUnnotedToolCallId(conversationId: conversationId)
            }
            let note = WorkingMemoryNote(
                section: section,
                content: content,
                intent: intent,
                associatedToolCallId: associatedToolCallId
            )
            await workingMemoryStore.add(conversationId: conversationId, note: note)

            // Mark the tool result as noted
            if let toolCallId = associatedToolCallId {
                await MainActor.run {
                    noteTracker?.markNoted(toolCallId: toolCallId, intent: intent)
                }
            }

            let count = await workingMemoryStore.noteCount(conversationId: conversationId)
            return successResponse(action: "add", section: section, noteCount: count)

        case "update":
            await workingMemoryStore.updateSection(
                conversationId: conversationId,
                section: section,
                content: content,
                intent: intent
            )
            let count = await workingMemoryStore.noteCount(conversationId: conversationId)
            return successResponse(action: "update", section: section, noteCount: count)

        case "clear":
            await workingMemoryStore.clearSection(conversationId: conversationId, section: section)
            let count = await workingMemoryStore.noteCount(conversationId: conversationId)
            return successResponse(action: "clear", section: section, noteCount: count)

        default:
            return errorResponse("action must be 'add', 'update', or 'clear'.", code: "INVALID_ACTION")
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

    private func errorResponse(_ message: String, code: String) -> String {
        """
        status: error
        message: "\(message)"
        error:
          code: \(code)
          recoverable: true
        """
    }
}
