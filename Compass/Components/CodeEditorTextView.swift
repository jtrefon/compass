import AppKit

@MainActor
final class CodeEditorTextView: NSTextView {
    let foldingManager = CodeFoldingManager()
    private lazy var foldingDelegate = FoldingLayoutManagerDelegate(manager: foldingManager, textView: self)
    private let ghostTextView = CodeEditorTextView.makeGhostTextView()
    private var ghostPresentation: InlineSuggestionPresentation?
    private var scrollObs: NSKeyValueObservation?

    /// Set to `true` while SnippetCompletionService is inserting a preview.
    /// The coordinator uses this to suppress automatic line-completion triggers.
    var snippetPreviewInProgress: Bool = false

    var hasInlineSuggestion: Bool {
        ghostPresentation != nil
    }

    var inlineSuggestionText: String? {
        ghostPresentation?.suggestionText
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview != nil {
            if ghostTextView.superview == nil {
                addSubview(ghostTextView)
            }
            observeScrollView()
        } else {
            scrollObs = nil
        }
    }

    private func observeScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        scrollObs?.invalidate()
        scrollObs = scrollView.contentView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateGhostTextFrame()
            }
        }
    }

    func configureFolding() {
        layoutManager?.delegate = foldingDelegate
    }

    override func layout() {
        super.layout()
        updateGhostTextFrame()
    }

    func updateGhostSuggestion(_ presentation: InlineSuggestionPresentation) {
        ghostPresentation = presentation
        ghostTextView.isHidden = false
        let fullText = String(presentation.suggestionText.prefix(600))
        let ghostLine = firstLine(of: fullText)
        let attrs = ghostTextAttributes()
        ghostTextView.textStorage?.setAttributedString(NSAttributedString(string: ghostLine, attributes: attrs))
        let tip = "\(presentation.source.rawValue) \u{2022} \(Int(presentation.latencyMs))ms"
        ghostTextView.toolTip = tip
        ghostTextView.font = font
        updateGhostTextFrame()
    }

    func clearInlineSuggestion() {
        ghostPresentation = nil
        ghostTextView.string = ""
        ghostTextView.toolTip = nil
        ghostTextView.isHidden = true
    }

    @discardableResult
    func acceptInlineSuggestion() -> Bool {
        guard let suggestion = ghostPresentation?.suggestionText, !suggestion.isEmpty else {
            return false
        }

        clearInlineSuggestion()
        // Insert only the FIRST line of the suggestion, matching what the ghost text shows.
        // For single-line completions (type-ahead) this is the entire suggestion.
        // For multiline suggestions that slip through, only the visible portion is inserted.
        let firstLine = suggestion.components(separatedBy: .newlines).first ?? suggestion
        insertText(firstLine, replacementRange: selectedRange)
        return true
    }

    private func firstLine(of text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? text
        return String(line.prefix(200))
    }



    private func updateGhostTextFrame() {
        guard ghostPresentation != nil, !ghostTextView.isHidden else { return }
        guard let layoutManager, let textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)

        let cursor = selectedRange.location
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: cursor, length: 0), actualCharacterRange: nil)
        var cursorRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        cursorRect = cursorRect.offsetBy(dx: origin.x, dy: origin.y)

        let width = max(bounds.width - cursorRect.minX - 8, 120)
        ghostTextView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        ghostTextView.frame = NSRect(
            x: cursorRect.minX,
            y: cursorRect.minY + 1,
            width: width,
            height: 1
        )
        if let lm = ghostTextView.layoutManager, let tc = ghostTextView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            ghostTextView.frame.size.height = max(used.height + 2, self.font?.pointSize ?? 12)
        }
    }

    private func ghostTextAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: paragraph
        ]
    }

    private static func makeGhostTextView() -> NSTextView {
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.isHidden = true
        return textView
    }

    // MARK: - Folding

    @IBAction func toggleFoldAtCursor(_ sender: Any?) {
        let cursor = selectedRange.location
        let range = CodeFoldingRangeFinder.foldRange(at: cursor, in: string)
        guard let range else { return }

        foldingManager.toggle(range: range)
        reflowForFoldingChange()
    }

    @IBAction func unfoldAll(_ sender: Any?) {
        foldingManager.unfoldAll()
        reflowForFoldingChange()
    }

    private func reflowForFoldingChange() {
        guard let layoutManager else { return }
        guard let textContainer else { return }
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: (string as NSString).length),
            actualCharacterRange: nil
        )
        layoutManager.ensureLayout(for: textContainer)

        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: - Current Line Highlight

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    // MARK: - Multi-cursor (VS Code style)

    @IBAction func addNextOccurrence(_ sender: Any?) {
        let ns = string as NSString

        let existingRanges = selectedRanges
            .compactMap { $0.rangeValue }
            .sorted(by: { $0.location < $1.location })

        let primary = existingRanges.last ?? selectedRange
        let needleRange: NSRange
        if primary.length > 0 {
            needleRange = primary
        } else {
            guard let word = wordRange(at: primary.location, in: ns) else { return }
            needleRange = word
        }

        let needle = ns.substring(with: needleRange)
        let fromIndex = max(
            NSMaxRange(needleRange),
            NSMaxRange(existingRanges.last ?? needleRange)
        )
        guard let next = MultiCursorUtilities.nextOccurrenceRange(
            text: string,
            needle: needle,
            fromIndex: fromIndex
        ) else { return }

        var newSelections = existingRanges
        newSelections.append(next)
        setSelectedRanges(
            uniqueSorted(newSelections).map { NSValue(range: $0) },
            affinity: .downstream,
            stillSelecting: false
        )
        scrollRangeToVisible(next)
    }

    @IBAction func addCursorAbove(_ sender: Any?) {
        addCursorVertically(direction: .up)
    }

    @IBAction func addCursorBelow(_ sender: Any?) {
        addCursorVertically(direction: .down)
    }

    private func addCursorVertically(direction: MultiCursorVerticalDirection) {
        let existingRanges = selectedRanges
            .compactMap { $0.rangeValue }
            .sorted(by: { $0.location < $1.location })

        let base = existingRanges.isEmpty ? [selectedRange] : existingRanges
        var out = existingRanges

        for range in base {
            let caret = range.location
            if let moved = MultiCursorUtilities.caretMovedVertically(text: string, caret: caret, direction: direction) {
                out.append(NSRange(location: moved, length: 0))
            }
        }

        setSelectedRanges(uniqueSorted(out).map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }

    private func uniqueSorted(_ ranges: [NSRange]) -> [NSRange] {
        var seen = Set<String>()
        let sorted = ranges.sorted { left, right in
            if left.location != right.location { return left.location < right.location }
            return left.length < right.length
        }
        var out: [NSRange] = []
        for range in sorted {
            let key = "\(range.location):\(range.length)"
            if seen.insert(key).inserted {
                out.append(range)
            }
        }
        return out
    }

    private func wordRange(at index: Int, in ns: NSString) -> NSRange? {
        let safe = max(0, min(index, ns.length))
        if ns.length == 0 { return nil }

        func isWord(_ characterString: String) -> Bool {
            guard let scalar = characterString.unicodeScalars.first else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || characterString == "_"
        }

        var start = safe
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if !isWord(ch) { break }
            start -= 1
        }

        var end = safe
        while end < ns.length {
            let ch = ns.substring(with: NSRange(location: end, length: 1))
            if !isWord(ch) { break }
            end += 1
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
