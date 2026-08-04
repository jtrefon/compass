import SwiftUI
import AppKit
import Combine

extension TextViewRepresentable {

    enum TextMutationEvent {
        case textDidChange(String, NSRange)
        case selectionDidChange(String, NSRange, isProgrammatic: Bool)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: TextViewRepresentable
        var currentLanguageIdentifier: String
        var isProgrammaticUpdate = false
        var isProgrammaticSelectionUpdate = false
        var currentFilePath: String?
        weak var attachedTextView: NSTextView?
        let signalBridge: EditorSignalBridge?
        var lastKnownBufferText: String = ""

        let mutationSubject = PassthroughSubject<TextMutationEvent, Never>()
        private var cancellables = Set<AnyCancellable>()
        private var enterHandledByShouldChange = false

        init(_ parent: TextViewRepresentable) {
            self.parent = parent
            self.currentLanguageIdentifier = parent.language
            self.currentFilePath = parent.filePath
            self.signalBridge = EditorSignalBridge(
                paneID: parent.paneID,
                lineEngine: parent.lineCompletionEngine
            )
            super.init()
        }

        func attach(textView: NSTextView) {
            self.attachedTextView = textView
            configureInlineCompletionHandlers()
            setupMutationSubscription()
        }

        private func setupMutationSubscription() {
            mutationSubject
                .sink { [weak self] event in
                    self?.handleMutationEvent(event)
                }
                .store(in: &cancellables)
        }

        @MainActor
        private func handleMutationEvent(_ event: TextMutationEvent) {
            guard let textView = attachedTextView else { return }

            switch event {
            case .textDidChange(let text, let range):
                parent.text = text
                parent.selectedRange = range
                lastKnownBufferText = text
                updateSelectionContext(from: textView)
                if !isProgrammaticUpdate {
                    scheduleAutomaticInlineCompletionIfNeeded(for: textView)
                }

            case .selectionDidChange(let text, let range, let isProgrammatic):
                parent.selectedRange = range
                updateSelectionContext(from: textView)

                guard !isProgrammatic else { return }

                if text == lastKnownBufferText {
                    (textView as? CodeEditorTextView)?.clearInlineSuggestion()
                    invalidateInlineCompletion()
                } else {
                    (textView as? CodeEditorTextView)?.clearInlineSuggestion()
                }
            }
        }

        deinit {
            let engine = parent.lineCompletionEngine
            let paneID = parent.paneID
            Task { @MainActor in
                engine.unregisterSuggestionHandler(for: paneID)
                InlineCompletionDebugStore.shared.update(paneID: paneID, presentation: nil)
            }
        }

        // MARK: - Real-time editor behaviors

        @MainActor
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if isProgrammaticUpdate { return true }

            if let codeEditorTextView = textView as? CodeEditorTextView,
               codeEditorTextView.hasInlineSuggestion,
               replacementString != nil {
                codeEditorTextView.clearInlineSuggestion()
                invalidateInlineCompletion()
            }

            guard let replacementString else { return true }

            if replacementString.count != 1 { return true }

            let character = replacementString
            let openToClose: [String: String] = [
                "(": ")",
                "[": "]",
                "{": "}",
                "\"": "\"",
                "'": "'"
            ]

            if character == "\n" || character == "\r" {
                enterHandledByShouldChange = true
                let result = handleContextualNewline(in: textView)
                return result
            }

            if let close = openToClose[character] {
                return handleAutoPair(open: character, close: close, in: textView, affectedCharRange: affectedCharRange)
            }

            let closingTokens: Set<String> = [")", "]", "}", "\"", "'"]
            if closingTokens.contains(character) {
                return handleSkipOverClosingIfPresent(character, in: textView)
            }

            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let codeEditorTextView = textView as? CodeEditorTextView else {
                return false
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if enterHandledByShouldChange {
                    enterHandledByShouldChange = false
                    return true
                }
                let shouldAllowDefault = handleContextualNewline(in: textView)
                return !shouldAllowDefault
            }

            if commandSelector == #selector(NSResponder.insertTab(_:)), codeEditorTextView.hasInlineSuggestion {
                let acceptedSuggestion = codeEditorTextView.inlineSuggestionText
                let accepted = codeEditorTextView.acceptInlineSuggestion()
                if accepted {
                    parent.lineCompletionEngine.markAccepted(
                        on: parent.paneID,
                        suggestionText: acceptedSuggestion
                    )
                    parent.text = textView.string
                    parent.selectedRange = textView.selectedRange
                    updateSelectionContext(from: textView)
                }
                return accepted
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)), codeEditorTextView.hasInlineSuggestion {
                codeEditorTextView.clearInlineSuggestion()
                parent.lineCompletionEngine.markDismissed()
                invalidateInlineCompletion()
                return true
            }

            return false
        }

        @MainActor
        private func handleAutoPair(
            open: String,
            close: String,
            in textView: NSTextView,
            affectedCharRange: NSRange
        ) -> Bool {
            let selected = textView.selectedRange
            if selected.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selected)
                let replacement = open + selectedText + close

                isProgrammaticUpdate = true
                textView.insertText(replacement, replacementRange: selected)
                textView.setSelectedRange(NSRange(location: selected.location + 1 + selected.length, length: 0))
                isProgrammaticUpdate = false
                mutationSubject.send(.textDidChange(textView.string, textView.selectedRange))
                return false
            }

            if (open == "\"" || open == "'") && nextCharacter(in: textView) == close {
                return true
            }

            isProgrammaticUpdate = true
            textView.insertText(open + close, replacementRange: affectedCharRange)
            textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
            isProgrammaticUpdate = false
            mutationSubject.send(.textDidChange(textView.string, textView.selectedRange))
            return false
        }

        @MainActor
        private func handleSkipOverClosingIfPresent(_ closingToken: String, in textView: NSTextView) -> Bool {
            let sel = textView.selectedRange
            if sel.length != 0 { return true }

            if nextCharacter(in: textView) == closingToken {
                isProgrammaticSelectionUpdate = true
                defer { isProgrammaticSelectionUpdate = false }
                textView.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return false
            }

            return true
        }

        @MainActor
        private func handleContextualNewline(in textView: NSTextView) -> Bool {
            let sel = textView.selectedRange
            if sel.length != 0 { return true }

            let nsString = textView.string as NSString
            let cursor = sel.location
            let safeCursor = max(0, min(cursor, nsString.length))

            let codeEditorTextView = textView as? CodeEditorTextView
            let pendingSuggestion = codeEditorTextView?.inlineSuggestionText
            if pendingSuggestion != nil {
                codeEditorTextView?.clearInlineSuggestion()
                invalidateInlineCompletion()
            }

            let indentUnit = detectIndent(from: textView.string)
            let currentLineRange = nsString.lineRange(for: NSRange(location: safeCursor, length: 0))
            let currentLine = nsString.substring(with: currentLineRange)
            let baseIndent = leadingWhitespace(of: currentLine)

            let prefixLength = max(0, min(safeCursor - currentLineRange.location, currentLineRange.length))
            let linePrefix = (currentLine as NSString).substring(to: prefixLength)
            let trimmedPrefix = linePrefix.trimmingCharacters(in: .whitespacesAndNewlines)

            if previousCharacter(in: textView) == "{" && nextCharacter(in: textView) == "}" {
                let innerIndent = baseIndent + indentUnit
                let insertion = "\n" + innerIndent + "\n" + baseIndent

                isProgrammaticUpdate = true
                textView.insertText(insertion, replacementRange: NSRange(location: safeCursor, length: 0))
                let newCursor = safeCursor + 1 + (innerIndent as NSString).length
                textView.setSelectedRange(NSRange(location: newCursor, length: 0))
                if let suggestion = pendingSuggestion {
                    textView.insertText(suggestion, replacementRange: textView.selectedRange)
                }
                isProgrammaticUpdate = false
                mutationSubject.send(.textDidChange(textView.string, textView.selectedRange))
                return false
            }

            var targetIndent = baseIndent
            if trimmedPrefix.hasSuffix("{") || trimmedPrefix.hasSuffix(":") {
                targetIndent = baseIndent + indentUnit
            } else if nextNonWhitespaceCharacter(in: nsString, from: safeCursor) == "}" {
                targetIndent = dropOneIndent(from: baseIndent, indentUnit: indentUnit)
            }

            let insertion = "\n" + targetIndent + (pendingSuggestion ?? "")

            isProgrammaticUpdate = true
            textView.insertText(insertion, replacementRange: NSRange(location: safeCursor, length: 0))
            let newCursor = safeCursor + 1 + (targetIndent as NSString).length
            textView.setSelectedRange(NSRange(location: newCursor, length: 0))
            isProgrammaticUpdate = false
            mutationSubject.send(.textDidChange(textView.string, textView.selectedRange))
            return false
        }

        private func nextNonWhitespaceCharacter(in nsString: NSString, from index: Int) -> String? {
            if index < 0 || index >= nsString.length { return nil }
            var scanIndex = index
            while scanIndex < nsString.length {
                let character = nsString.substring(with: NSRange(location: scanIndex, length: 1))
                if character != " " && character != "\t" && character != "\n" && character != "\r" {
                    return character
                }
                scanIndex += 1
            }
            return nil
        }

        private func dropOneIndent(from baseIndent: String, indentUnit: String) -> String {
            if baseIndent.hasSuffix(indentUnit) {
                return String(baseIndent.dropLast((indentUnit as NSString).length))
            }
            if baseIndent.hasSuffix("\t") {
                return String(baseIndent.dropLast(1))
            }
            let spacesToRemove = min(indentUnit.count, baseIndent.count)
            return String(baseIndent.dropLast(spacesToRemove))
        }

        @MainActor
        private func currentLineIndent(in textView: NSTextView) -> String {
            let nsString = textView.string as NSString
            let cursor = textView.selectedRange.location
            let safeCursor = max(0, min(cursor, nsString.length))

            let lineRange = nsString.lineRange(for: NSRange(location: safeCursor, length: 0))
            if lineRange.location == NSNotFound || lineRange.length == 0 { return "" }

            let line = nsString.substring(with: lineRange)
            return leadingWhitespace(of: line)
        }

        private func leadingWhitespace(of text: String) -> String {
            var result = ""
            for character in text {
                if character == " " || character == "\t" {
                    result.append(character)
                } else {
                    break
                }
            }
            return result
        }

        /// Detects the indent style used in the file content.
        /// Returns the indent unit string (e.g. "\t", "  ", "    ") that matches
        /// the prevailing style, falling back to the global preference if
        /// the file has no detectable indentation.
        private func detectIndent(from content: String) -> String {
            let lines = content.components(separatedBy: .newlines)
            var tabCount = 0
            var spaceCounts: [Int: Int] = [:]

            for line in lines.prefix(100) {
                let indent = leadingWhitespace(of: line)
                guard indent.count > 0 else { continue }

                if indent.contains("\t") {
                    tabCount += 1
                    continue
                }
                spaceCounts[indent.count, default: 0] += 1
            }

            if tabCount > 0 {
                return "\t"
            }

            if let (width, _) = spaceCounts.max(by: { $0.value < $1.value }) {
                return String(repeating: " ", count: width)
            }

            return IndentationStyle.current().indentUnit(tabWidth: AppConstants.Editor.tabWidth)
        }

        @MainActor
        private func previousCharacter(in textView: NSTextView) -> String? {
            let nsString = textView.string as NSString
            let pos = textView.selectedRange.location
            if pos <= 0 || pos > nsString.length { return nil }
            return nsString.substring(with: NSRange(location: pos - 1, length: 1))
        }

        @MainActor
        private func nextCharacter(in textView: NSTextView) -> String? {
            let nsString = textView.string as NSString
            let pos = textView.selectedRange.location
            if pos < 0 || pos >= nsString.length { return nil }
            return nsString.substring(with: NSRange(location: pos, length: 1))
        }
    }
}
