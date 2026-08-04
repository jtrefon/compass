//
//  MessageFilterCoordinator.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import Foundation

/// Coordinates message filtering logic for display
@MainActor
struct MessageFilterCoordinator {

    // MARK: - Public Methods

    /// Filters messages to display, removing empty assistant messages
    func filterMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { shouldDisplayMessage($0, in: messages) }
    }

    /// Determines if a message should be displayed in the list
    func shouldDisplayMessage(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        if !ChatMessageVisibilityPolicy.shouldDisplayMessage(message) {
            return false
        }

        if message.role == .assistant {
            let cleaned = ChatPromptBuilder.contentForDisplay(from: message.content)
            let hasReasoning = !(message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasContent = !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasContent && !hasReasoning {
                return false
            }
        }

        if message.role == .system {
            return ReasoningOutcomeMessageView.parse(from: message.content) != nil
        }

        if message.isToolExecution {
            return shouldDisplayToolExecutionMessage(message, in: messages)
        }

        return true
    }

    // MARK: - Private Methods

    private func shouldDisplayToolExecutionMessage(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard let toolCallId = message.toolCallId else {
            return true
        }

        guard let latestForId = messages.last(where: { $0.toolCallId == toolCallId }) else {
            return true
        }

        return message.id == latestForId.id
    }
}
