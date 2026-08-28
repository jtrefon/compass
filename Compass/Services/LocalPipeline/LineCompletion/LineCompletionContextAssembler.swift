import Foundation

/// Builds the FIM input window from the editor snapshot.
///
/// The window is **line-anchored**: the prefix start is pinned to the line
/// boundary at (cursor − budget) instead of sliding one char per keystroke.
/// A sliding window breaks the token prefix between consecutive keystrokes
/// (every key re-encodes the whole prompt — measured `common=1, delta=411`
/// in fim-trace.ndjson), which defeats the FIM KV cache. With a stable start
/// the prefix only grows, so KV reuse re-encodes just the delta.
@MainActor
struct LineCompletionContextAssembler {
    private let prefixChars = 1500
    private let suffixChars = 300

    func buildContext(from snapshot: InlineCompletionEditorSnapshot) -> CompletionContextPayload {
        let nsBuffer = snapshot.buffer as NSString
        let safeCursor = max(0, min(snapshot.cursorPosition, nsBuffer.length))

        let prefixStart = anchoredPrefixStart(in: nsBuffer, cursor: safeCursor, budget: prefixChars)
        let suffixEnd = min(nsBuffer.length, safeCursor + suffixChars)

        let prefix = nsBuffer.substring(with: NSRange(location: prefixStart, length: safeCursor - prefixStart))
        let suffix = nsBuffer.substring(with: NSRange(location: safeCursor, length: suffixEnd - safeCursor))

        return CompletionContextPayload(
            prefix: prefix,
            suffix: suffix
        )
    }

    /// Pin the window start to the line boundary at (cursor − budget): the
    /// start stays fixed while typing within that line, so the token prefix
    /// is append-aligned between keystrokes.
    private func anchoredPrefixStart(in buffer: NSString, cursor: Int, budget: Int) -> Int {
        let rawStart = max(0, cursor - budget)
        guard rawStart > 0 else { return 0 }
        let newlineRange = buffer.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: rawStart)
        )
        guard newlineRange.location != NSNotFound else { return 0 }
        return newlineRange.location + 1
    }
}
