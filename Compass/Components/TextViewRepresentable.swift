import SwiftUI
import AppKit
import SyntaxHighlighting

@MainActor
struct TextViewRepresentable: NSViewRepresentable {
    let paneID: FileEditorStateManager.PaneID
    @Binding var text: String
    let filePath: String?
    var language: String
    @Binding var selectedRange: NSRange?
    @ObservedObject var selectionContext: CodeSelectionContext
    let lineCompletionEngine: LineCompletionEngine
    var showLineNumbers: Bool
    var wordWrap: Bool
    var fontSize: Double
    var fontFamily: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CodeEditorTextView()

        let resolvedFont = Self.resolveEditorFont(fontFamily: fontFamily, fontSize: fontSize)
        configureTextView(textView, resolvedFont: resolvedFont)
        configureTextContainerSizing(for: textView)
        setInitialText(in: textView, coordinator: context.coordinator)
        attachCoordinator(context.coordinator, to: textView)
        configureScrollView(scrollView, documentView: textView)
        scheduleInitialWordWrapApply(scrollView, textView: textView)
        configureLineNumbersIfNeeded(scrollView, textView: textView)
        attachHighlighter(to: textView, language: language)

        return scrollView
    }

    private func configureTextView(_ textView: NSTextView, resolvedFont: NSFont) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = resolvedFont
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = NSColor.labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        textView.setAccessibilityIdentifier(AccessibilityID.codeEditorTextView)
        (textView as? CodeEditorTextView)?.configureFolding()
    }

    private func configureTextContainerSizing(for textView: NSTextView) {
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
    }

    private func setInitialText(in textView: NSTextView, coordinator: Coordinator) {
        coordinator.isProgrammaticUpdate = true
        textView.string = text
        coordinator.isProgrammaticUpdate = false
    }

    private func attachCoordinator(_ coordinator: Coordinator, to textView: NSTextView) {
        textView.delegate = coordinator
        coordinator.attach(textView: textView)
    }

    private func configureScrollView(_ scrollView: NSScrollView, documentView: NSTextView) {
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
    }

    private func scheduleInitialWordWrapApply(_ scrollView: NSScrollView, textView: NSTextView) {
        Task { @MainActor in
            Self.applyWordWrap(wordWrap, to: scrollView, textView: textView)
        }
    }

    private func configureLineNumbersIfNeeded(_ scrollView: NSScrollView, textView: NSTextView) {
        guard showLineNumbers else {
            return
        }

        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = ModernLineNumberRulerView(scrollView: scrollView, textView: textView)

        Task { @MainActor in
            scrollView.tile()
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    private func attachHighlighter(to textView: NSTextView, language: String) {
        TreeSitterHighlightService.shared.attachHighlighter(to: textView, languageIdentifier: language)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let resolvedFont = Self.resolveEditorFont(fontFamily: fontFamily, fontSize: fontSize)
        let languageDidChange = context.coordinator.currentLanguageIdentifier != language
        let fileDidChange = context.coordinator.currentFilePath != filePath
        context.coordinator.currentLanguageIdentifier = language
        context.coordinator.currentFilePath = filePath
        let needsRehighlight = syncFont(resolvedFont, for: textView, in: scrollView)

        if languageDidChange || fileDidChange {
            TreeSitterHighlightService.shared.attachHighlighter(to: textView, languageIdentifier: language)
        }

        scheduleWordWrapUpdate(for: scrollView, textView: textView)
        syncTextIfNeeded(for: textView, coordinator: context.coordinator, resolvedFont: resolvedFont, needsRehighlight: needsRehighlight)
        syncSelectionIfNeeded(for: textView, coordinator: context.coordinator)
        syncRulerVisibilityIfNeeded(for: scrollView, textView: textView)
        if fileDidChange {
            context.coordinator.handleFileSwitch(textView: textView)
        }
    }

    private func syncFont(_ resolvedFont: NSFont, for textView: NSTextView, in scrollView: NSScrollView) -> Bool {
        var needsRehighlight = false
        if textView.font != resolvedFont {
            textView.font = resolvedFont
            needsRehighlight = true
        }

        if let ruler = scrollView.verticalRulerView as? ModernLineNumberRulerView {
            ruler.updateFont(resolvedFont)
        }

        return needsRehighlight
    }

    private func scheduleWordWrapUpdate(for scrollView: NSScrollView, textView: NSTextView) {
        Task { @MainActor in
            Self.applyWordWrap(wordWrap, to: scrollView, textView: textView)
        }
    }

    private func syncTextIfNeeded(
        for textView: NSTextView,
        coordinator: Coordinator,
        resolvedFont: NSFont,
        needsRehighlight: Bool
    ) {
        let current = textView.string
        if current != text {
            applyProgrammaticTextUpdate(text, to: textView, coordinator: coordinator)
        }
    }

    private func applyProgrammaticTextUpdate(_ newText: String, to textView: NSTextView, coordinator: Coordinator) {
        coordinator.isProgrammaticUpdate = true
        textView.string = newText
        coordinator.isProgrammaticUpdate = false
    }

    private func syncSelectionIfNeeded(for textView: NSTextView, coordinator: Coordinator) {
        guard let range = selectedRange,
              range.location != NSNotFound,
              range.location + range.length <= (textView.string as NSString).length else {
            return
        }

        if textView.selectedRange() == range {
            return
        }

        coordinator.isProgrammaticSelectionUpdate = true
        defer { coordinator.isProgrammaticSelectionUpdate = false }
        textView.setSelectedRange(range)
    }

    private func syncRulerVisibilityIfNeeded(for scrollView: NSScrollView, textView: NSTextView) {
        let shouldShowRuler = showLineNumbers
        if scrollView.hasVerticalRuler != shouldShowRuler || scrollView.rulersVisible != shouldShowRuler {
            scrollView.hasVerticalRuler = shouldShowRuler
            scrollView.rulersVisible = shouldShowRuler
            if shouldShowRuler && scrollView.verticalRulerView == nil {
                scrollView.verticalRulerView = ModernLineNumberRulerView(scrollView: scrollView, textView: textView)
            }
        }
    }

    static func resolveEditorFont(fontFamily: String, fontSize: Double) -> NSFont {
        let size = CGFloat(fontSize)

        if let font = NSFont(name: fontFamily, size: size) {
            return font
        }

        if let font = NSFontManager.shared.font(
            withFamily: fontFamily,
            traits: .fixedPitchFontMask,
            weight: 5,
            size: size
        ) {
            return font
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func applyWordWrap(_ enabled: Bool, to scrollView: NSScrollView, textView: NSTextView) {
        guard let container = textView.textContainer else { return }

        if enabled {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
