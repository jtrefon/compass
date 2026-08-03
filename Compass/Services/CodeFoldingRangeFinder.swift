import Foundation

/// Computes foldable ranges for source text using a conservative brace-pair heuristic.
///
/// Notes:
/// - All indices are UTF-16 (NSString / NSRange) based.
/// - This does not attempt to be language-aware; it only tracks `{` / `}` pairs.
public enum CodeFoldingRangeFinder {
    public static func foldRange(at cursor: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        let safeCursor = max(0, min(cursor, ns.length))
        let pairs = bracePairs(in: ns)

        // Find the smallest fold range that contains the cursor.
        let containing = pairs.compactMap { pair -> NSRange? in
            guard let range = foldContentRange(pair: pair, in: ns) else { return nil }
            guard range.length > 0 else { return nil }
            if safeCursor >= range.location && safeCursor <= NSMaxRange(range) {
                return range
            }
            return nil
        }

        return containing.min(by: { $0.length < $1.length })
    }

    public static func allFoldRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return bracePairs(in: ns).compactMap { foldContentRange(pair: $0, in: ns) }
            .filter { $0.length > 0 }
    }

    // MARK: - Internals

    private static func bracePairs(in ns: NSString) -> [CodeFoldingBracePair] {
        var stack: [Int] = []
        var pairs: [CodeFoldingBracePair] = []

        var index = 0
        while index < ns.length {
            let ch = ns.substring(with: NSRange(location: index, length: 1))
            if ch == "{" {
                stack.append(index)
            } else if ch == "}" {
                if let open = stack.popLast(), open < index {
                    pairs.append(CodeFoldingBracePair(open: open, close: index))
                }
            }
            index += 1
        }

        return pairs
    }

    private static func foldContentRange(pair: CodeFoldingBracePair, in ns: NSString) -> NSRange? {
        // Fold the content *between* braces, excluding the braces themselves.
        let start = pair.open + 1
        let end = pair.close
        guard start < end, start >= 0, end <= ns.length else { return nil }

        let range = NSRange(location: start, length: end - start)

        // Only fold if it spans multiple lines.
        let content = ns.substring(with: range)
        if !content.contains("\n") && !content.contains("\r") { return nil }

        return range
    }
}
