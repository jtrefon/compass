import Foundation

/// Incremental streaming buffer that classifies model output into content,
/// reasoning, and tool-text containers.
///
/// Classification is **deferred** — no O(n) scanning per chunk. The raw
/// content is accumulated and only classified when `flushClassification()` is
/// called. This keeps chunk ingestion O(1) so the main thread is never
/// blocked by streaming input.
final class StreamingOutputBuffer {
    // MARK: - Containers

    private(set) var content: String = ""
    private(set) var reasoning: String = ""
    private(set) var toolText: String = ""

    // MARK: - Internal State

    /// Accumulated raw text from content stream, not yet classified
    private var rawContent: String = ""
    /// Accumulated raw reasoning from dedicated reasoning stream
    private var rawReasoning: String = ""
    /// Unprocessed portion that has been appended since last flush
    private var pending: String = ""
    /// Whether the last pending chunk ended inside a <think> block
    private var insideThinkingBlock: Bool = false

    private static let thinkingOpenTag = "<think>"
    private static let thinkingCloseTag = "</think>"

    // MARK: - Append (O(1) — no scanning)

    func appendContent(_ chunk: String) {
        pending.append(chunk)
        rawContent.append(chunk)
    }

    func appendReasoning(_ chunk: String) {
        rawReasoning.append(chunk)
        reasoning = rawReasoning
    }

    /// Run classification on pending data and update content/reasoning/toolText.
    /// Call this from the display flush path, NOT from appendContent.
    func flushClassification() {
        guard !pending.isEmpty else { return }
        defer { pending = "" }

        // When reasoning comes via a separate stream, content is pure visible text
        guard rawReasoning.isEmpty else {
            content = rawContent
            toolText = ""
            return
        }

        let result = classifyIncremental(pending, wasInsideBlock: insideThinkingBlock)
        insideThinkingBlock = result.wasInsideBlock
        let c = result.classified
        content += c.content
        if !c.reasoning.isEmpty {
            reasoning += c.reasoning
        }
        if toolText.isEmpty, !c.toolText.isEmpty {
            toolText = c.toolText
        }
    }

    /// Incremental thinking-block + tool-text classification.
    /// Only processes `incoming` — does NOT re-scan previously classified text.
    private func classifyIncremental(
        _ incoming: String,
        wasInsideBlock: Bool
    ) -> (classified: (content: String, reasoning: String, toolText: String), wasInsideBlock: Bool) {
        var outContent = ""
        var outReasoning = ""
        var remaining = incoming
        var isInside = wasInsideBlock

        if isInside {
            if let closeRange = remaining.range(of: Self.thinkingCloseTag) {
                outReasoning += remaining[remaining.startIndex..<closeRange.lowerBound]
                remaining = String(remaining[closeRange.upperBound...])
                isInside = false
            } else {
                outReasoning += remaining
                return ((outContent, outReasoning, ""), isInside)
            }
        }

        while let openRange = remaining.range(of: Self.thinkingOpenTag) {
            outContent += remaining[remaining.startIndex..<openRange.lowerBound]
            let afterOpen = remaining[openRange.upperBound...]

            if let closeRange = afterOpen.range(of: Self.thinkingCloseTag) {
                outReasoning += afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                remaining = String(afterOpen[closeRange.upperBound...])
            } else {
                outReasoning += String(afterOpen)
                isInside = true
                remaining = ""
            }
        }

        outContent += remaining

        let toolText = detectToolText(outContent)

        return ((outContent, outReasoning, toolText), isInside)
    }

    /// Check if the classified content looks like an unparsed tool-call block
    private func detectToolText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return "" }

        let patterns: [String] = [
            "\"name\":", "\"arguments\":", "\"function\":",
            "\"type\": \"function\"", "tool_calls",
        ]
        let matchCount = patterns.filter { trimmed.lowercased().contains($0.lowercased()) }.count
        return matchCount >= 2 ? text : ""
    }

    // MARK: - Access

    var hasContent: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasReasoning: Bool {
        reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: - Reset

    func clear() {
        content = ""
        reasoning = ""
        toolText = ""
        rawContent = ""
        rawReasoning = ""
        pending = ""
        insideThinkingBlock = false
    }
}
