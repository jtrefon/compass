import Foundation

// MARK: - NoteIntent

/// Intent declared by the model when writing a note.
/// Controls whether the raw tool result is evictable.
enum NoteIntent: String, Codable, Sendable {
    /// Read for understanding — raw read disposable after noting.
    case finding
    /// Read for editing — raw read preserved through context resets.
    case editTarget
}

// MARK: - WorkingMemoryNote

/// A single note in working memory — the model's persistent finding.
struct WorkingMemoryNote: Codable, Sendable, Identifiable {
    let id: String
    let section: String
    let content: String
    let intent: NoteIntent
    let timestamp: Date
    var associatedToolCallId: String?

    init(
        id: String = UUID().uuidString,
        section: String,
        content: String,
        intent: NoteIntent,
        timestamp: Date = Date(),
        associatedToolCallId: String? = nil
    ) {
        self.id = id
        self.section = section
        self.content = content
        self.intent = intent
        self.timestamp = timestamp
        self.associatedToolCallId = associatedToolCallId
    }
}

// MARK: - WorkingMemorySnapshot

/// A snapshot of working memory for a conversation.
struct WorkingMemorySnapshot: Codable, Sendable {
    var notes: [WorkingMemoryNote] = []
    var lastResetAt: Date?

    var isEmpty: Bool { notes.isEmpty }

    func notesBySection() -> [String: [WorkingMemoryNote]] {
        Dictionary(grouping: notes) { $0.section }
    }

    func editTargetSections() -> Set<String> {
        Set(notes.filter { $0.intent == .editTarget }.map { $0.section })
    }

    /// Render the snapshot as compact text for Mission Control.
    /// Notes are grouped by section; each note is rendered as its content line.
    func renderForContext(maxNotes: Int = 15) -> String {
        guard !notes.isEmpty else {
            return "No notes yet — call note() after reading files to build your working memory."
        }

        let sortedNotes = notes.suffix(maxNotes)
        let grouped = Dictionary(grouping: sortedNotes) { $0.section }
            .sorted { $0.key < $1.key }

        var lines: [String] = []
        for (section, sectionNotes) in grouped {
            lines.append("**\(section):**")
            for note in sectionNotes {
                lines.append(note.content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - KeyExcerpt

/// A key excerpt selected by the NPU from a tool result.
struct KeyExcerpt: Codable, Sendable, Identifiable {
    let id: String
    let filePath: String
    let lineStart: Int
    let lineEnd: Int
    let text: String
    let relevanceScore: Float
    let sourceToolCallId: String
    let timestamp: Date

    var lineRangeDescription: String { "\(lineStart)-\(lineEnd)" }

    init(
        id: String = UUID().uuidString,
        filePath: String,
        lineStart: Int,
        lineEnd: Int,
        text: String,
        relevanceScore: Float,
        sourceToolCallId: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.text = text
        self.relevanceScore = relevanceScore
        self.sourceToolCallId = sourceToolCallId
        self.timestamp = timestamp
    }
}

// MARK: - BudgetInfo

/// Computed context budget information for Mission Control.
struct BudgetInfo: Sendable {
    let usedTokens: Int
    let contextLength: Int

    var percentUsed: Int {
        guard contextLength > 0 else { return 0 }
        return (usedTokens * 100) / contextLength
    }

    var remainingTokens: Int {
        max(0, contextLength - usedTokens)
    }
}
