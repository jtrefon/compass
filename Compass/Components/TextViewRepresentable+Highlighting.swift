import SwiftUI
import AppKit
import Combine

extension TextViewRepresentable.Coordinator {

    @MainActor
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        mutationSubject.send(.textDidChange(textView.string, textView.selectedRange))
    }

    @MainActor
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let isProgrammatic = isProgrammaticUpdate || isProgrammaticSelectionUpdate
        mutationSubject.send(.selectionDidChange(textView.string, textView.selectedRange, isProgrammatic: isProgrammatic))
    }

    @MainActor
    func updateSelectionContext(from textView: NSTextView) {
        let range = textView.selectedRange
        if range.location != NSNotFound,
           range.length > 0,
           range.location + range.length <= (textView.string as NSString).length {
            let selected = (textView.string as NSString).substring(with: range)
            parent.selectionContext.selectedText = selected
            parent.selectionContext.selectedRange = range
        } else {
            parent.selectionContext.selectedText = ""
            parent.selectionContext.selectedRange = nil
        }
    }
}
