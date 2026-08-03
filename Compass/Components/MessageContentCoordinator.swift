//
//  MessageContentCoordinator.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import SwiftUI
import Foundation
import AppKit

/// Coordinates message content rendering and styling
@MainActor
struct MessageContentCoordinator {

    // MARK: - Properties

    let message: ChatMessage
    var fontSize: Double
    var fontFamily: String
    @Binding var isReasoningHidden: Bool

    // MARK: - Initialization

    init(message: ChatMessage, fontSize: Double, fontFamily: String, isReasoningHidden: Binding<Bool>) {
        self.message = message
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self._isReasoningHidden = isReasoningHidden
    }

    // MARK: - Public Methods

    /// Creates the appropriate message content view based on message type
    func makeMessageContent() -> some View {
        Group {
            if message.isToolExecution {
                ToolExecutionMessageView(
                    message: message,
                    fontSize: fontSize,
                    fontFamily: fontFamily
                )
            } else if isReasoningOutcomeMessage {
                ReasoningOutcomeMessageView(
                    message: message,
                    fontSize: fontSize
                )
            } else {
                assistantMessageContent
            }
        }
    }

    private var assistantMessageContent: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if hasReasoning {
                ReasoningMessageView(
                    reasoning: message.reasoning ?? "",
                    fontSize: fontSize,
                    isReasoningHidden: $isReasoningHidden
                )
            }

            if hasVisibleContent {
                MarkdownMessageView(
                    content: visibleContent,
                    fontSize: fontSize,
                    fontFamily: fontFamily
                )
                .padding(.horizontal, AppConstants.Layout.spacingMd)
                .padding(.vertical, AppConstants.Layout.spacingSm)
                .background(bubbleBackground(for: message))
                .foregroundColor(bubbleForegroundColor(for: message))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: bubbleRadius(message, corner: .topLeft),
                    bottomLeadingRadius: bubbleRadius(message, corner: .bottomLeft),
                    bottomTrailingRadius: bubbleRadius(message, corner: .bottomRight),
                    topTrailingRadius: bubbleRadius(message, corner: .topRight),
                    style: .continuous
                ))
                .textSelection(.enabled)
                .contextMenu {
                    copyMessageButton
                }
            }

            if hasToolCalls {
                ToolCallsSummaryView(
                    toolCalls: message.toolCalls ?? [],
                    fontSize: fontSize
                )
            }
        }
    }

    // MARK: - Private Methods

    private func bubbleBackground(for message: ChatMessage) -> Color {
        if message.role == .user {
            return AppConstants.Color.accentDefault
        }

        return AppConstants.Color.surfaceCard
    }

    private func bubbleForegroundColor(for message: ChatMessage) -> Color {
        if message.role == .user {
            return AppConstants.Color.textOnAccent
        }

        return AppConstants.Color.textPrimary
    }

    private func bubbleRadius(_ message: ChatMessage, corner: Corner) -> CGFloat {
        let isUser = message.role == .user
        let small = AppConstants.Layout.cornerSm
        let large = AppConstants.Layout.cornerLg
        switch corner {
        case .topLeft, .topRight:
            return isUser ? small : large
        case .bottomLeft:
            return isUser ? small : large
        case .bottomRight:
            return isUser ? large : small
        }
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private var hasReasoning: Bool {
        guard let reasoning = message.reasoning else { return false }
        return !reasoning.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
    }

    private var hasToolCalls: Bool {
        !(message.toolCalls?.isEmpty ?? true)
    }

    private var hasVisibleContent: Bool {
        !visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleContent: String {
        let split = ChatPromptBuilder.splitReasoning(from: message.content)
        return split.content
    }

    private var isReasoningOutcomeMessage: Bool {
        message.role == .system && ReasoningOutcomeMessageView.parse(from: message.content) != nil
    }

    private var copyMessageButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Text(localized("chat.copy_message"))
            Image(systemName: "doc.on.doc")
        }
    }

}
