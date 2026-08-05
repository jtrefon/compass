import Foundation

@MainActor
struct LineCompletionContextAssembler {
    func buildContext(from snapshot: InlineCompletionEditorSnapshot) -> CompletionContextPayload {
        let nsBuffer = snapshot.buffer as NSString
        let safeCursor = max(0, min(snapshot.cursorPosition, nsBuffer.length))

        let prefixChars = 1500
        let suffixChars = 300

        let prefixStart = max(0, safeCursor - prefixChars)
        let suffixEnd = min(nsBuffer.length, safeCursor + suffixChars)

        let prefix = nsBuffer.substring(with: NSRange(location: prefixStart, length: safeCursor - prefixStart))
        let suffix = nsBuffer.substring(with: NSRange(location: safeCursor, length: suffixEnd - safeCursor))

        return CompletionContextPayload(
            prefix: prefix,
            suffix: suffix
        )
    }
}
