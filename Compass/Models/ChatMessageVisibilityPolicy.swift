import Foundation

struct ChatMessageVisibilityPolicy {
    /// Determines if an assistant message should be considered "empty" for filtering purposes.
    /// Draft messages (during streaming) are never considered empty - they should always be visible.
    static func isEmptyAssistantMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        
        // Draft messages should always be visible during streaming
        if message.isDraft {
            return false
        }

        let isContentEmpty = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isReasoningEmpty = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let isToolCallsEmpty = message.toolCalls?.isEmpty ?? true

        return isContentEmpty && isReasoningEmpty && isToolCallsEmpty
    }
    
    /// Determines if a message should be displayed in the UI.
    /// Draft messages are always displayed, non-draft messages are filtered if empty.
    /// Tool execution messages are deduplicated (latest per toolCallId) by MessageFilterCoordinator.
    static func shouldDisplayMessage(_ message: ChatMessage) -> Bool {
        if isSyntheticAssistantProgressMessage(message) {
            return false
        }
        if message.isDraft {
            return true
        }
        return !isEmptyAssistantMessage(message)
    }

    static func isSyntheticAssistantProgressMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }

        let normalized = ChatPromptBuilder.contentForDisplay(from: message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let syntheticPrefixes = [
            "done -> next -> path:",
            "done → next → path:",
            "completed progress update for step ",
            "start checkpoint scan.",
            "checking checkpoints pass "
        ]

        if syntheticPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        if !(message.toolCalls?.isEmpty ?? true),
           (
                normalized.contains(" next: ")
                || normalized.contains(" next →")
                || normalized.contains("done ->")
                || normalized.contains("done →")
           ) {
            return true
        }

        let reasoning = message.reasoning?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !reasoning.isEmpty,
           reasoning.contains("what:"),
           reasoning.contains("how:"),
           reasoning.contains("where:"),
           normalized.contains(" next: ") {
            return true
        }

        return false
    }
}
