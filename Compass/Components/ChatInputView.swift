//
//  ChatInputView.swift
//  Compass
//
//  Created by AI Assistant on 25/08/2025.
//

import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let isSending: Bool
    var fontSize: Double
    var fontFamily: String
    let onSend: () -> Void
    var onStop: (() -> Void)? = nil

    @FocusState private var isInputFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func resolveFont(size: Double, family: String) -> Font {
        if let nsFont = NSFont(name: family, size: CGFloat(size)) {
            return Font(nsFont)
        }
        return .system(size: CGFloat(size), weight: .regular, design: .monospaced)
    }

    private var inputShape: some Shape {
        RoundedRectangle(cornerRadius: AppConstants.Layout.cornerLg, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: AppConstants.Layout.spacingSm) {
            TextField(localized("chat_input.placeholder"), text: $text, axis: .vertical)
                .font(resolveFont(size: fontSize, family: fontFamily))
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: true)
                .onSubmit(sendIfPossible)
                .padding(.horizontal, AppConstants.Layout.spacingMd)
                .padding(.vertical, AppConstants.Layout.spacingSm)
                .background {
                    inputShape
                        .fill(AppConstants.Color.surfaceCard)
                        .glassEffect(.regular, in: inputShape)
                }
                .overlay(
                    inputShape
                        .stroke(
                            isInputFocused ? AppConstants.Color.focusRing : AppConstants.Color.separatorSubtle,
                            lineWidth: isInputFocused ? AppConstants.Layout.focusRingWidth : AppConstants.Layout.panelDividerVisibleThickness
                        )
                )
                .accessibilityIdentifier(AccessibilityID.aiChatInputTextView)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: isSending ? { onStop?() } : sendIfPossible) {
                    if isSending {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, AppConstants.Color.alertError)
                            .background {
                                Circle()
                                    .fill(AppConstants.Color.alertError)
                                    .glassEffect(.regular, in: Circle())
                            }
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                canSend ? Color.white : AppConstants.Color.textTertiary.opacity(0.5),
                                canSend ? AppConstants.Color.accentDefault : Color.clear
                            )
                            .background {
                                if canSend {
                                    Circle()
                                        .fill(AppConstants.Color.accentDefault)
                                        .glassEffect(.regular, in: Circle())
                                }
                            }
                            .clipShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSending ? localized("chat_input.stop") : localized("chat_input.send"))
                .accessibilityIdentifier(isSending ? AccessibilityID.aiChatStopButton : AccessibilityID.aiChatSendButton)
                .disabled(!isSending && !canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, AppConstants.Layout.spacingSm)
        .padding(.top, AppConstants.Layout.spacingSm)
        .padding(.bottom, AppConstants.Layout.spacingSm)
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend()
    }
}

struct ChatInputView_Previews: PreviewProvider {
    static var previews: some View {
        ChatInputView(
            text: .constant("Hello, how can you help me?"),
            isSending: false,
            fontSize: 12,
            fontFamily: AppConstants.Editor.defaultFontFamily,
            onSend: {}
        )
    }
}
