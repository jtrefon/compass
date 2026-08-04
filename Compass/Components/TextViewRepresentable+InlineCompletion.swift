import AppKit
import SwiftUI

extension TextViewRepresentable.Coordinator {
    @MainActor
    func configureInlineCompletionHandlers() {
        let paneID = parent.paneID

        parent.lineCompletionEngine.registerSuggestionHandler(for: paneID) { [weak self] presentation in
            InlineCompletionDebugStore.shared.update(paneID: paneID, presentation: presentation)
            guard let self, let textView = self.attachedTextView as? CodeEditorTextView else { return }
            if let presentation {
                textView.updateGhostSuggestion(presentation)
            } else {
                textView.clearInlineSuggestion()
            }
        }
    }

    @MainActor
    func unregisterInlineCompletionHandlers() {
        parent.lineCompletionEngine.unregisterSuggestionHandler(for: parent.paneID)
        InlineCompletionDebugStore.shared.update(paneID: parent.paneID, presentation: nil)
    }

    @MainActor
    func handleFileSwitch(textView: NSTextView) {
        guard let signalBridge else { return }
        (textView as? CodeEditorTextView)?.clearInlineSuggestion()
        InlineCompletionDebugStore.shared.update(paneID: parent.paneID, presentation: nil)
        signalBridge.invalidate(textView: textView as? CodeEditorTextView)
    }

    @MainActor
    func scheduleAutomaticInlineCompletionIfNeeded(for textView: NSTextView) {
        guard let signalBridge else { return }
        guard let codeEditor = textView as? CodeEditorTextView else { return }
        guard !codeEditor.snippetPreviewInProgress else { return }

        let snapshot = makeSnapshot(from: textView, triggerReason: .automatic)
        signalBridge.scheduleAutomaticRequest(snapshot: snapshot)
    }

    @MainActor
    func invalidateInlineCompletion() {
        InlineCompletionDebugStore.shared.update(paneID: parent.paneID, presentation: nil)
        signalBridge?.invalidate(textView: attachedTextView as? CodeEditorTextView)
    }

    @MainActor
    func makeSnapshot(
        from textView: NSTextView,
        triggerReason: CompletionTriggerReason
    ) -> InlineCompletionEditorSnapshot {
        let selection = textView.selectedRange
        return InlineCompletionEditorSnapshot(
            paneID: parent.paneID,
            filePath: parent.filePath,
            language: currentLanguageIdentifier,
            buffer: textView.string,
            cursorPosition: selection.location,
            selectionLength: selection.length,
            isComposingText: textView.hasMarkedText(),
            triggerReason: triggerReason
        )
    }
}
