//
//  ReasoningMessageView.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import SwiftUI
import Foundation

/// View for displaying collapsible reasoning content
struct ReasoningMessageView: View {
    let reasoning: String
    var fontSize: Double
    @Binding var isReasoningHidden: Bool
    @State private var showFullReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            reasoningToggleButton

            if !isReasoningHidden {
                reasoningContent
            }
        }
        .padding(.horizontal, AppConstants.Layout.spacingMd)
        .padding(.vertical, AppConstants.Layout.spacingSm)
        .nativeGlassBackground(.panel, cornerRadius: AppConstants.Layout.cornerLg)
    }

    // MARK: - Private Components

    private var reasoningToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isReasoningHidden.toggle()
            }
        } label: {
            HStack(spacing: AppConstants.Layout.spacingSm) {
                Image(systemName: "brain")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppConstants.Color.accentDefault)
                Text(localized("reasoning.title"))
                    .font(.system(size: CGFloat(max(10, fontSize - 2)), weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isReasoningHidden ? "chevron.down" : "chevron.up")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppConstants.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var reasoningContent: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingXS) {
            let text = ChatPromptBuilder.reasoningForDisplay(reasoning)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if showFullReasoning || text.count <= 300 {
                Text(text)
                    .font(.system(size: CGFloat(max(10, fontSize - 2))))
                    .foregroundStyle(AppConstants.Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(String(text.prefix(300)) + "…")
                    .font(.system(size: CGFloat(max(10, fontSize - 2))))
                    .foregroundStyle(AppConstants.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(showFullReasoning ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showFullReasoning.toggle()
                    }
                }
                .font(.system(size: CGFloat(max(9, fontSize - 3))))
                .buttonStyle(.plain)
                .foregroundStyle(AppConstants.Color.accentDefault)
            }
        }
    }
}
