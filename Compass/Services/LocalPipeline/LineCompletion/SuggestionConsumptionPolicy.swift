import Foundation

/// Pure head-consumption logic (accept-verify): given candidate suggestion
/// texts and the buffer before the cursor, decide whether the typed text
/// extends a candidate's head and what remainder to show. No model call.
/// The caller owns timing/pool rules; this type owns the matching.
struct SuggestionConsumptionPolicy {
    static let maxHeadScanLength = 60

    struct Result {
        let consumedText: String
        /// The suggestion minus the consumed head; nil when fully consumed.
        let remainder: String?
    }

    /// The best (first-ranked) candidate whose head the buffer extends.
    /// Iterates candidates in order and, per candidate, tries the longest
    /// head first (up to `maxHeadScanLength`).
    static func consume(
        from candidates: [InlineCompletionVariant],
        bufferBeforeCursor: String
    ) -> Result? {
        for variant in candidates where !variant.text.isEmpty {
            let maxHeadLen = min(variant.text.count, maxHeadScanLength)
            if maxHeadLen <= 0 { continue }
            for headLen in stride(from: maxHeadLen, through: 1, by: -1) {
                if bufferBeforeCursor.hasSuffix(variant.text.prefix(headLen)) {
                    let remaining = String(variant.text.dropFirst(headLen))
                    return Result(
                        consumedText: variant.text,
                        remainder: remaining.isEmpty ? nil : remaining
                    )
                }
            }
        }
        return nil
    }
}
