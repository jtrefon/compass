import Foundation

public enum MultiCursorUtilities {
    /// Returns the next occurrence of `needle` in `text` starting at `fromIndex`.
    /// All indices are UTF-16 based.
    public static func nextOccurrenceRange(text: String, needle: String, fromIndex: Int) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let ns = text as NSString
        let start = max(0, min(fromIndex, ns.length))
        let searchRange = NSRange(location: start, length: ns.length - start)
        let found = ns.range(of: needle, options: [], range: searchRange)
        return found.location != NSNotFound ? found : nil
    }

    /// Returns the line range (including newline) containing `index`.
    public static func lineRange(text: NSString, index: Int) -> NSRange {
        let safeIndex = max(0, min(index, text.length))
        return text.lineRange(for: NSRange(location: safeIndex, length: 0))
    }

    /// Returns caret index moved one line up/down keeping the same column when possible.
    public static func caretMovedVertically(
        text: String,
        caret: Int,
        direction: MultiCursorVerticalDirection
    ) -> Int? {
        let ns = text as NSString
        let safeCaret = max(0, min(caret, ns.length))
        let currentLine = lineRange(text: ns, index: safeCaret)
        let column = safeCaret - currentLine.location

        switch direction {
        case .up:
            guard currentLine.location > 0 else { return nil }
            let prevIndex = max(0, currentLine.location - 1)
            let prevLine = lineRange(text: ns, index: prevIndex)
            return clampCaret(in: prevLine, desiredColumn: column, text: ns)
        case .down:
            let nextIndex = NSMaxRange(currentLine)
            guard nextIndex < ns.length else { return nil }
            let nextLine = lineRange(text: ns, index: nextIndex)
            return clampCaret(in: nextLine, desiredColumn: column, text: ns)
        }
    }

    private static func clampCaret(in line: NSRange, desiredColumn: Int, text: NSString) -> Int {
        // Exclude trailing newline(s) from the target.
        let lineText = text.substring(with: line)
        var usableLength = (lineText as NSString).length
        if lineText.hasSuffix("\r\n") {
            usableLength = max(0, usableLength - 2)
        } else if lineText.hasSuffix("\n") || lineText.hasSuffix("\r") {
            usableLength = max(0, usableLength - 1)
        }

        let col = max(0, min(desiredColumn, usableLength))
        return line.location + col
    }

}
