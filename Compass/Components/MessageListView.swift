//
//  MessageListView.swift
//  Compass
//
//  Created by AI Assistant on 25/08/2025.
//

import Foundation
import SwiftUI

private struct TypingDotsBubbleView: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(dotOpacity(for: index, time: time))
                        .scaleEffect(dotScale(for: index, time: time))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
                .background(AppConstants.Color.surfaceCard.opacity(0.5))
            .clipShape(Capsule())
            .frame(height: AppConstants.Layout.headerHeight)
            .opacity(isActive ? 1 : 0)
            .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isActive)
        }
    }

    private func dotOpacity(for index: Int, time: TimeInterval) -> Double {
        guard isActive else { return 0.18 }
        let wave = (sin((time * 4.4) - (Double(index) * 0.6)) + 1) / 2
        return 0.3 + (wave * 0.7)
    }

    private func dotScale(for index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else { return 0.8 }
        let wave = (sin((time * 4.4) - (Double(index) * 0.6)) + 1) / 2
        return 0.8 + CGFloat(wave * 0.35)
    }
}

struct MessageListView: View {
    let messages: [ChatMessage]
    let isSending: Bool
    var fontSize: Double
    var fontFamily: String
    
    @State private var globalReasoningExpanded = false
    @State private var userManuallyToggledReasoning = false
    @State private var reasoningAutoCloseTask: Task<Void, Never>?

    private let filterCoordinator = MessageFilterCoordinator()

    private var visibleMessages: [ChatMessage] {
        messages.filter { filterCoordinator.shouldDisplayMessage($0, in: messages) }
    }

    private var messageCount: Int {
        visibleMessages.count
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    private var reasoningHiddenBinding: Binding<Bool> {
        Binding(
            get: { !globalReasoningExpanded },
            set: { isHidden in
                userManuallyToggledReasoning = true
                globalReasoningExpanded = !isHidden
                reasoningAutoCloseTask?.cancel()
            }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let maxBubbleWidth = min(880, max(260, geometry.size.width * 0.92))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleMessages) { message in
                            MessageView(
                                message: message,
                                fontSize: fontSize,
                                fontFamily: fontFamily,
                                maxBubbleWidth: maxBubbleWidth,
                                isReasoningHidden: reasoningHiddenBinding
                            )
                            .id(message.id)
                        }

                        typingIndicator(maxBubbleWidth: maxBubbleWidth)

                        Color.clear
                            .frame(height: 1)
                            .id("__bottom__")
                    }
                    .padding(.horizontal, AppConstants.Layout.spacingMd)
                    .padding(.vertical, AppConstants.Layout.spacingMd)
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: messageCount) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isSending) { _, newValue in
                    scrollToBottom(proxy: proxy)
                    if newValue {
                        // Auto-open reasoning during streaming
                        if !globalReasoningExpanded {
                            globalReasoningExpanded = true
                        }
                    } else {
                        // Auto-close after 5s if user didn't manually open
                        if !userManuallyToggledReasoning {
                            reasoningAutoCloseTask?.cancel()
                            reasoningAutoCloseTask = Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    globalReasoningExpanded = false
                                }
                            }
                        }
                        userManuallyToggledReasoning = false
                    }
                }
            }
        }
    }

    // MARK: - Private Components

    private func typingIndicator(maxBubbleWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            TypingDotsBubbleView(isActive: isSending)
                .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            Spacer()
        }
        .frame(height: AppConstants.Layout.headerHeight)
        .accessibilityHidden(!isSending)
    }
}

struct MessageView: View {
    let message: ChatMessage
    var fontSize: Double
    var fontFamily: String
    var maxBubbleWidth: CGFloat
    @Binding var isReasoningHidden: Bool

    private let contentCoordinator: MessageContentCoordinator

    init(
        message: ChatMessage,
        fontSize: Double,
        fontFamily: String,
        maxBubbleWidth: CGFloat,
        isReasoningHidden: Binding<Bool>
    ) {
        self.message = message
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.maxBubbleWidth = maxBubbleWidth
        self._isReasoningHidden = isReasoningHidden
        self.contentCoordinator = MessageContentCoordinator(
            message: message,
            fontSize: fontSize,
            fontFamily: fontFamily,
            isReasoningHidden: isReasoningHidden
        )
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                roleLabel
                contentCoordinator.makeMessageContent()
                if let codeContext = message.codeContext {
                    CodePreviewView(
                        code: codeContext,
                        fontSize: fontSize,
                        fontFamily: fontFamily
                    )
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: message.role == .user ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: - Private Components

    private var roleLabel: some View {
        Text(roleLabelText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var roleLabelText: String {
        let timestamp = message.timestamp.formatted(date: .omitted, time: .standard)
        guard let requestCostMicrodollars = message.billing?.requestCostMicrodollars else {
            return timestamp
        }
        return "\(timestamp) · \(CostDisplayFormatter.dollarAmount(fromMicrodollars: requestCostMicrodollars))"
    }
}

struct MessageListView_Previews: PreviewProvider {
    static var previews: some View {
        MessageListView(
            messages: [
                ChatMessage(role: .assistant, content: "Hello! How can I help you today?"),
                ChatMessage(role: .user, content: "Can you explain this code?"),
                ChatMessage(
                    role: .assistant, content: "Sure! This code implements a chat interface."),
            ],
            isSending: true,
            fontSize: 12,
            fontFamily: "Menlo"
        )
    }
}
