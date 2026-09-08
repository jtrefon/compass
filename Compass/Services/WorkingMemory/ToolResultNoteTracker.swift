import Foundation

/// Tracks tool result → note associations.
/// When the model calls `note()`, the system correlates the note with the
/// most recent un-noted tool result. This lets the eviction logic know which
/// tool results are safe to evict (finding) and which must be preserved (edit_target).
///
/// `@MainActor` (not `actor`) so that `PipelineProcessor.prepareForRequestNoteAware`
/// can access it synchronously from the `@MainActor` request preparation path.
@MainActor
final class ToolResultNoteTracker {
    static let shared = ToolResultNoteTracker()

    private struct ToolCallStatus {
        var noted: Bool
        var intent: NoteIntent?
        var conversationId: String
        var order: Int
    }

    private var status: [String: ToolCallStatus] = [:]
    private var orderCounter: Int = 0

    func recordToolResult(toolCallId: String, conversationId: String) {
        orderCounter += 1
        status[toolCallId] = ToolCallStatus(
            noted: false,
            intent: nil,
            conversationId: conversationId,
            order: orderCounter
        )
    }

    func markNoted(toolCallId: String, intent: NoteIntent) {
        guard var existing = status[toolCallId] else { return }
        existing.noted = true
        existing.intent = intent
        status[toolCallId] = existing
    }

    func isEvictable(toolCallId: String) -> Bool {
        guard let s = status[toolCallId] else { return true }
        if !s.noted { return false }
        if s.intent == .editTarget { return false }
        return true
    }

    func isFinding(toolCallId: String) -> Bool {
        guard let s = status[toolCallId] else { return false }
        return s.noted && s.intent == .finding
    }

    func isEditTarget(toolCallId: String) -> Bool {
        guard let s = status[toolCallId] else { return false }
        return s.noted && s.intent == .editTarget
    }

    func markEditComplete(toolCallId: String) {
        guard var existing = status[toolCallId] else { return }
        existing.intent = .finding
        status[toolCallId] = existing
    }

    func lastUnnotedToolCallId(conversationId: String) -> String? {
        let filtered = status.filter { !$0.value.noted && $0.value.conversationId == conversationId }
        return filtered.max { $0.value.order < $1.value.order }?.key
    }

    func clear(conversationId: String) {
        status = status.filter { $0.value.conversationId != conversationId }
    }
}
