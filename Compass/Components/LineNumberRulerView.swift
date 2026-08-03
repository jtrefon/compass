import AppKit

final class ModernLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var font: NSFont
    private let textColor: NSColor
    private let selectionColor: NSColor

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        self.font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        self.textColor = NSColor.secondaryLabelColor
        self.selectionColor = NSColor.systemBlue.withAlphaComponent(0.2)

        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 50
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
    }

    @objc private func scrollViewDidScroll() {
        needsDisplay = true
    }

    @objc private func selectionDidChange() {
        needsDisplay = true
    }

    func updateFont(_ font: NSFont?) {
        guard let font else { return }
        guard self.font != font else { return }
        self.font = font
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated static func startingLineNumber(string: NSString, firstCharIndex: Int) -> Int {
        guard firstCharIndex > 0 else { return 1 }

        // IMPORTANT: NSTextView / NSLayoutManager indices are UTF-16 (NSString) based.
        // Do not mix Swift String.count (grapheme clusters) with NSRange locations.
        var count = 1
        var pos = 0
        while pos < firstCharIndex {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let next = NSMaxRange(lineRange)
            guard next > pos else { break }
            if next <= firstCharIndex {
                count += 1
            }
            pos = next
        }
        return count
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        NSColor.clear.setFill()
        rect.fill()

        let relativePoint = convert(NSPoint.zero, from: textView)
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        let string = textView.string as NSString
        let firstCharIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

        let lineNumber = Self.startingLineNumber(string: string, firstCharIndex: firstCharIndex)
        let context = DrawLineNumbersContext(
            textView: textView,
            string: string,
            layoutManager: layoutManager,
            textContainer: textContainer,
            glyphRange: glyphRange,
            relativePoint: relativePoint,
            startingLineNumber: lineNumber
        )
        drawLineNumbers(context: context)
    }

    private struct DrawLineNumbersContext {
        let textView: NSTextView
        let string: NSString
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let glyphRange: NSRange
        let relativePoint: NSPoint
        let startingLineNumber: Int
    }

    private func drawLineNumbers(context: DrawLineNumbersContext) {
        var lineNumber = context.startingLineNumber
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        var glyphIndex = context.glyphRange.location
        while glyphIndex < NSMaxRange(context.glyphRange) {
            let charIndex = context.layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = getLineRange(context: context, charIndex: charIndex)
            let charRange = NSRange(location: lineRange.start, length: max(0, lineRange.end - lineRange.start))
            let lineGlyphRange = context.layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var lineRect = context.layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: context.textContainer)
            lineRect.origin.x += context.relativePoint.x
            lineRect.origin.y += context.relativePoint.y

            drawLineNumber(
                lineNumber,
                at: lineRect,
                drawContext: DrawLineNumberContext(
                    attrs: attrs,
                    context: context,
                    charIndex: charIndex,
                    lineCharRange: charRange
                )
            )

            let nextGlyphIndex = NSMaxRange(lineGlyphRange)
            glyphIndex = nextGlyphIndex > glyphIndex ? nextGlyphIndex : (glyphIndex + 1)
            lineNumber += 1
        }
    }

    private func getLineRange(context: DrawLineNumbersContext, charIndex: Int) -> (start: Int, end: Int) {
        var lineStart: Int = 0
        var lineEnd: Int = 0
        context.string.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: NSRange(location: charIndex, length: 0))
        return (lineStart, lineEnd)
    }

    private struct DrawLineNumberContext {
        let attrs: [NSAttributedString.Key: Any]
        let context: DrawLineNumbersContext
        let charIndex: Int
        let lineCharRange: NSRange
    }

    private func drawLineNumber(_ lineNumber: Int, at lineRect: NSRect, drawContext: DrawLineNumberContext) {
        let label = "\(lineNumber)" as NSString
        let cursor = drawContext.context.textView.selectedRange.location
        let isCurrentLine = cursor >= drawContext.lineCharRange.location && cursor < NSMaxRange(drawContext.lineCharRange)

        var attrs = drawContext.attrs
        if isCurrentLine {
            attrs[.foregroundColor] = NSColor.secondaryLabelColor.blended(withFraction: 0.4, of: .labelColor) ?? NSColor.labelColor

            let highlightRect = NSRect(x: 0, y: lineRect.minY, width: ruleThickness, height: lineRect.height)
            selectionColor.setFill()
            highlightRect.fill()
        }

        let labelSize = label.size(withAttributes: attrs)
        let labelY = lineRect.minY + (lineRect.height - labelSize.height) / 2
        let labelX = ruleThickness - 6 - labelSize.width

        label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
    }

}
