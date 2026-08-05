import AppKit

/// Alternatives dropdown for the FIM variant pool (FIM_VariantPools_Arch.md
/// §5). Rendered as a subview of the editor near the cursor; keyboard-driven
/// (arrows navigate, Tab/Enter accept the highlighted variant, Escape closes).
/// Reads the already-warm pool — no inference happens behind it.
@MainActor
final class InlineCompletionDropdownView: NSView {
    static let rowHeight: CGFloat = 22
    static let maxRows = 5

    private(set) var items: [String] = []
    private(set) var selectedIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setItems(_ newItems: [String]) {
        items = Array(newItems.prefix(Self.maxRows))
        if selectedIndex >= items.count {
            selectedIndex = max(0, items.count - 1)
        }
        frame.size = NSSize(width: 340, height: CGFloat(items.count) * Self.rowHeight + 8)
        needsDisplay = true
    }

    func moveSelection(up: Bool) -> Bool {
        guard items.count > 1 else { return false }
        let next = up ? selectedIndex - 1 : selectedIndex + 1
        guard next >= 0, next < items.count else { return false }
        selectedIndex = next
        needsDisplay = true
        return true
    }

    var selectedItem: String? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !items.isEmpty else { return }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let contentRect = bounds.insetBy(dx: 4, dy: 4)
        for (index, item) in items.enumerated() {
            let rowRect = NSRect(
                x: contentRect.minX,
                y: contentRect.minY + CGFloat(index) * Self.rowHeight,
                width: contentRect.width,
                height: Self.rowHeight
            )
            if index == selectedIndex {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
            }
            let display = item.replacingOccurrences(of: "\n", with: " ")
            let textRect = rowRect.insetBy(dx: 6, dy: 4)
            (display as NSString).draw(in: textRect, withAttributes: textAttrs)
        }
    }
}
