//
//  CodeEditorView.swift
//  Compass
//
//  Created by AI Assistant on 25/08/2025.
//

import SwiftUI

// CodeSelectionContext moved to Services/CodeSelectionContext.swift

struct CodeEditorView: View {
    let paneID: FileEditorStateManager.PaneID
    @Binding var text: String
    let filePath: String?
    var language: String
    @Binding var selectedRange: NSRange?
    @ObservedObject var selectionContext: CodeSelectionContext
    let lineCompletionEngine: LineCompletionEngine
    var inlineCompletionDebugOverlayEnabled: Bool = false
    var showLineNumbers: Bool = true
    var wordWrap: Bool = false
    var fontSize: Double = AppConstantsEditor.defaultFontSize
    var fontFamily: String = AppConstantsEditor.defaultFontFamily
    @ObservedObject private var inlineCompletionDebugStore = InlineCompletionDebugStore.shared
    @ObservedObject var inlineQAPopoverManager: InlineAIPopoverManager = .disabled

    var body: some View {
        GeometryReader { geometry in
            // Text editor (use AppKit's own NSScrollView; avoid nesting in SwiftUI ScrollView)
            TextViewRepresentable(
                paneID: paneID,
                text: $text,
                filePath: filePath,
                language: language,
                selectedRange: $selectedRange,
                selectionContext: selectionContext,
                lineCompletionEngine: lineCompletionEngine,
                showLineNumbers: showLineNumbers,
                wordWrap: wordWrap,
                fontSize: fontSize,
                fontFamily: fontFamily
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(
                inlineCompletionDebugOverlay,
                alignment: .topTrailing
            )
            .overlay(
                inlineQAPopoverOverlay,
                alignment: .topLeading
            )
        }
    }

    @ViewBuilder
    private var inlineQAPopoverOverlay: some View {
        if inlineQAPopoverManager.isVisible && inlineQAPopoverManager.paneID == paneID {
            InlineAIPopoverView(manager: inlineQAPopoverManager)
                .offset(
                    x: inlineQAPopoverManager.anchorRect.origin.x,
                    y: inlineQAPopoverManager.anchorRect.origin.y
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var inlineCompletionDebugOverlay: some View {
        if inlineCompletionDebugOverlayEnabled {
            let state = inlineCompletionDebugStore.state(for: paneID)

            VStack(alignment: .leading, spacing: AppConstants.Layout.spacingXS) {
                Text("Inline Completion")
                    .font(.caption.weight(.semibold).monospaced())

                if let state {
                    Text("\(state.source.rawValue) • \(Int(state.latencyMs))ms • \(Int(state.confidenceScore * 100))%")
                    Text(state.isMultiline ? "multiline" : "single-line")
                    Text(state.suggestionPreview.isEmpty ? "no preview" : state.suggestionPreview)
                        .lineLimit(3)
                } else {
                    Text("idle")
                    Text(filePath ?? "no file")
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppConstants.Layout.spacingMd)
            .padding(.vertical, AppConstants.Layout.spacingSm)
            .nativeGlassBackground(.popover, cornerRadius: AppConstants.Layout.cornerLg, showBorder: true)
            .padding(AppConstants.Layout.spacingMd)
            .allowsHitTesting(false)
        }
    }
}
