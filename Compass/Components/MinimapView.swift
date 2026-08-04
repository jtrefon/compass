import SwiftUI
import AppKit

struct MinimapView: View {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    var fontFamily: String

    var body: some View {
        MinimapRepresentable(text: $text, selectedRange: $selectedRange, fontFamily: fontFamily)
            .frame(minWidth: 90, idealWidth: 110, maxWidth: 140)
            .background(AppConstants.Color.surfaceEditor)
    }
}

@MainActor
private struct MinimapRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    var fontFamily: String

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let font = resolveFont(family: fontFamily)
        textView.font = font

        textView.string = text

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let font = resolveFont(family: fontFamily)
        if textView.font != font {
            textView.font = font
        }

        if textView.string != text {
            textView.string = text
        }

        if let range = selectedRange,
           range.location != NSNotFound,
           range.location <= (textView.string as NSString).length {
            textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        }
    }

    private func resolveFont(family: String) -> NSFont {
        let size: CGFloat = 3.5
        if let font = NSFont(name: family, size: size) {
            return font
        }
        if let font = NSFontManager.shared.font(
            withFamily: family,
            traits: .fixedPitchFontMask,
            weight: 5,
            size: size
        ) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
