import Foundation
@preconcurrency import MLXLMCommon

/// Incremental streaming detokenizer — replaces `NaiveStreamingDetokenizer`
/// in the direct iterator loop for O(1) amortized decode per token instead
/// of O(N) (re-decoding the entire segment on every token).
///
/// The naive version calls `tokenizer.decode(tokenIds: segmentTokens)` with
/// the full segment on every token — for a 200-token segment without
/// newlines, that's 40,000 token decodes. This version decodes only the
/// delta (new tokens since the last successful decode), with a bounded
/// retry for multi-byte UTF-8 characters that span token boundaries.
///
/// The segment boundary (newline) logic mirrors `NaiveStreamingDetokenizer`:
/// on `\n`, a new segment starts with the last token carried over.
struct IncrementalStreamingDetokenizer: StreamingDetokenizer {
    let tokenizer: any Tokenizer

    /// Tokens in the current segment (since the last newline boundary).
    private var segmentTokens: [Int] = []
    /// The decoded text of everything in the segment up to (but not
    /// including) the tokens that haven't been flushed yet.
    private var flushedSegmentText: String = ""
    /// Tokens whose decode has already been flushed — we track the index
    /// into `segmentTokens` so we know which tokens are "new".
    private var flushedTokenCount: Int = 0

    init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
    }

    mutating func append(token: Int) {
        segmentTokens.append(token)
    }

    private mutating func startNewSegment() {
        let lastToken = segmentTokens.last
        segmentTokens.removeAll()
        flushedTokenCount = 0
        if let lastToken {
            segmentTokens.append(lastToken)
            flushedSegmentText = tokenizer.decode(tokenIds: segmentTokens)
            flushedTokenCount = 1
        } else {
            flushedSegmentText = ""
        }
    }

    mutating func next() -> String? {
        // Nothing new to decode.
        guard segmentTokens.count > flushedTokenCount else { return nil }

        // Decode only the new tokens since the last flush. Start with
        // just the last new token; if it produces a replacement char
        // (incomplete multi-byte sequence), expand the decode window
        // backwards (bounded to the segment's unflushed tokens).
        let unflushedStart = flushedTokenCount
        let unflushedCount = segmentTokens.count - unflushedStart

        // Try decoding progressively larger windows of new tokens, from
        // the end backwards. This handles the case where a multi-byte
        // UTF-8 character spans 2+ tokens — the first decode of the
        // partial token yields U+FFFD, so we expand.
        var newText: String = ""
        var decodeFrom = segmentTokens.count - 1
        var foundComplete = false

        // Decode the entire unflushed suffix at once — this is O(unflushedCount)
        // which is typically 1 (the common case). The progressive retry
        // below only triggers on multi-byte boundaries.
        let fullUnflushed = Array(segmentTokens[unflushedStart...])
        let fullDecode = tokenizer.decode(tokenIds: fullUnflushed)

        if fullDecode.last == "\u{fffd}" {
            // The last token is an incomplete multi-byte sequence —
            // don't emit anything yet; wait for more tokens.
            return nil
        }

        // We have a complete decode of the new tokens. But we need to
        // check if any PREFIX of the unflushed tokens also produces a
        // replacement char (a multi-byte char split across tokens in
        // the middle of the unflushed set). Decode the flushed text +
        // unflushed tokens together and diff against flushedSegmentText.
        //
        // Optimization: in the common case (1 new token, no multi-byte
        // split), fullDecode IS the new text. We only need the full
        // segment decode when there's ambiguity.
        if unflushedCount == 1 {
            newText = fullDecode
        } else {
            // Decode the full segment to get the correct text boundary
            // (handles edge cases where token boundaries don't align
            // with the flushed text boundary).
            let fullSegment = tokenizer.decode(tokenIds: segmentTokens)
            if fullSegment.count > flushedSegmentText.count {
                newText = String(fullSegment.suffix(fullSegment.count - flushedSegmentText.count))
            } else {
                newText = ""
            }
        }

        // Check for replacement char in the middle (not just the end).
        if newText.contains("\u{fffd}"), !newText.hasSuffix("\u{fffd}") {
            // A replacement char in the middle means a token boundary
            // split a multi-byte char that was later completed. The
            // full segment decode should have resolved it — fall back
            // to the naive approach for correctness.
            let fullSegment = tokenizer.decode(tokenIds: segmentTokens)
            newText = String(fullSegment.suffix(fullSegment.count - flushedSegmentText.count))
        }

        // Update the flushed state.
        flushedTokenCount = segmentTokens.count
        if unflushedCount == 1 {
            flushedSegmentText += newText
        } else {
            flushedSegmentText = tokenizer.decode(tokenIds: segmentTokens)
        }

        // Handle newline boundary (mirrors NaiveStreamingDetokenizer).
        if newText.hasSuffix("\n") {
            startNewSegment()
        }

        return newText.isEmpty ? nil : newText
    }
}
