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

        let rawPrefix = nsBuffer.substring(with: NSRange(location: prefixStart, length: safeCursor - prefixStart))
        let prefix = rawPrefix
        let suffix = nsBuffer.substring(with: NSRange(location: safeCursor, length: suffixEnd - safeCursor))

        return CompletionContextPayload(
            prefix: prefix,
            suffix: suffix,
            scopeSummary: nearestScopeSummary(in: nsBuffer, cursor: safeCursor),
            symbols: []
        )
    }

    private func nearestScopeSummary(in buffer: NSString, cursor: Int) -> String? {
        let searchWindow = max(0, cursor - 1000)
        let snippet = buffer.substring(with: NSRange(location: searchWindow, length: cursor - searchWindow))
        let lines = snippet.components(separatedBy: .newlines).reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("func ") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") ||
                trimmed.hasPrefix("enum ") || trimmed.hasPrefix("protocol ") || trimmed.hasPrefix("extension ") {
                return trimmed
            }
        }
        return nil
    }
}
