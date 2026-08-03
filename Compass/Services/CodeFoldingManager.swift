import AppKit
import Foundation

public final class CodeFoldingManager: NSObject, @unchecked Sendable {
    private(set) var foldedRanges: [NSRange] = []

    public func isFolded(_ range: NSRange) -> Bool {
        foldedRanges.contains(where: { NSEqualRanges($0, range) })
    }

    public func isIndexFolded(_ index: Int) -> Bool {
        for range in foldedRanges {
            if index >= range.location && index < NSMaxRange(range) {
                return true
            }
        }
        return false
    }

    public func toggle(range: NSRange) {
        if let idx = foldedRanges.firstIndex(where: { NSEqualRanges($0, range) }) {
            foldedRanges.remove(at: idx)
        } else {
            foldedRanges.append(range)
        }
        normalize()
    }

    public func unfoldAll() {
        foldedRanges.removeAll()
    }

    private func normalize() {
        foldedRanges.sort { left, right in
            if left.location != right.location { return left.location < right.location }
            return left.length < right.length
        }
    }
}

@MainActor
public final class FoldingLayoutManagerDelegate: NSObject, NSLayoutManagerDelegate {
    nonisolated private let manager: CodeFoldingManager
    weak var textView: NSTextView?

    private struct GlyphGenerationOutput {
        let glyphs: [CGGlyph]
        let properties: [NSLayoutManager.GlyphProperty]
        let characterIndexes: [Int]
    }

    public init(manager: CodeFoldingManager, textView: NSTextView? = nil) {
        self.manager = manager
        self.textView = textView
    }

    nonisolated public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let count = glyphRange.length
        var outGlyphs: [CGGlyph] = Array(repeating: 0, count: count)
        var outProps: [NSLayoutManager.GlyphProperty] = Array(repeating: [], count: count)
        var outCharIndexes: [Int] = Array(repeating: 0, count: count)

        for index in 0..<count {
            let chIdx = charIndexes[index]
            outCharIndexes[index] = chIdx

            if manager.isIndexFolded(chIdx) {
                outGlyphs[index] = 0
                outProps[index] = .null
            } else {
                outGlyphs[index] = glyphs[index]
                outProps[index] = props[index]
            }
        }

        let output = GlyphGenerationOutput(
            glyphs: outGlyphs,
            properties: outProps,
            characterIndexes: outCharIndexes
        )
        setGlyphs(layoutManager: layoutManager, output: output, font: aFont, glyphRange: glyphRange)

        return count
    }

    nonisolated private func setGlyphs(
        layoutManager: NSLayoutManager,
        output: GlyphGenerationOutput,
        font: NSFont,
        glyphRange: NSRange
    ) {
        guard !output.glyphs.isEmpty,
              !output.properties.isEmpty,
              !output.characterIndexes.isEmpty else {
            return
        }

        output.glyphs.withUnsafeBufferPointer { gPtr in
            output.properties.withUnsafeBufferPointer { pPtr in
                output.characterIndexes.withUnsafeBufferPointer { cPtr in
                    guard let gBase = gPtr.baseAddress,
                          let pBase = pPtr.baseAddress,
                          let cBase = cPtr.baseAddress else {
                        return
                    }
                    
                    layoutManager.setGlyphs(
                        gBase,
                        properties: pBase,
                        characterIndexes: cBase,
                        font: font,
                        forGlyphRange: glyphRange
                    )
                }
            }
        }
    }

    public func layoutManager(_ layoutManager: NSLayoutManager, drawBackgroundForGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textView else { return }
        let cursor = textView.selectedRange.location
        let length = (textView.string as NSString).length
        guard cursor >= 0, cursor < length else { return }

        guard let textContainer = textView.textContainer else { return }

        var lineStart = 0, lineEnd = 0
        (textView.string as NSString).getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: NSRange(location: cursor, length: 0))

        let lineCharRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

        let drawnGlyphRange = NSIntersectionRange(lineGlyphRange, glyphsToShow)
        guard drawnGlyphRange.length > 0 else { return }

        var lineRect = layoutManager.boundingRect(forGlyphRange: drawnGlyphRange, in: textContainer)
        lineRect.origin.x += origin.x
        lineRect.origin.y += origin.y

        lineRect.size.width = max(textView.bounds.width - lineRect.origin.x, lineRect.width)

        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.2).setFill()
        lineRect.fill()
    }
}
