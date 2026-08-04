import Foundation

enum ToolMarkupStripper {
    static func stripMarkup(from content: String) -> String {
        var output = content
        for pattern in Self.stripPatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Gemma format: <|tool_call>call:name{...}</|tool_call> — the wrapper
        // regex can't balance braces, so call:...{...} regions are removed
        // with a balanced scan (same semantics as GemmaFormatParser).
        output = Self.stripGemmaToolCalls(from: output)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Content for a committed assistant message that carries tool calls:
    /// markup is stripped so the visible message and the next request never
    /// see raw `<|tool_call>call:...{...}` (or any provider's tool markup).
    /// Provider-agnostic — applied at the commit boundary, not inside any
    /// inference engine.
    static func assistantContent(_ content: String?, toolCalls: [AIToolCall]?) -> String {
        guard let content else { return "" }
        guard !(toolCalls?.isEmpty ?? true) else { return content }
        return stripMarkup(from: content)
    }

    /// Removes `call:name{...}` blocks (balanced-brace scan) plus the
    /// `<|tool_call>` / `</|tool_call>` wrapper tags.
    private static func stripGemmaToolCalls(from content: String) -> String {
        var output = content
        output = output.replacingOccurrences(of: "<|tool_call>", with: "")
        output = output.replacingOccurrences(of: "</|tool_call>", with: "")
        output = output.replacingOccurrences(of: "<|tool_call|>", with: "")

        let marker = "call:"
        var result = ""
        var searchStart = output.startIndex
        while let markerRange = output.range(of: marker, range: searchStart..<output.endIndex) {
            let afterMarker = markerRange.upperBound
            var nameEnd = afterMarker
            while nameEnd < output.endIndex,
                  output[nameEnd].isLetter || output[nameEnd].isNumber || output[nameEnd] == "_" {
                nameEnd = output.index(after: nameEnd)
            }
            var braceStart = nameEnd
            while braceStart < output.endIndex, output[braceStart].isWhitespace {
                braceStart = output.index(after: braceStart)
            }
            guard braceStart < output.endIndex, output[braceStart] == "{" else {
                result += String(output[searchStart..<markerRange.upperBound])
                searchStart = markerRange.upperBound
                continue
            }
            var depth = 1
            var pos = output.index(after: braceStart)
            while pos < output.endIndex, depth > 0 {
                let ch = output[pos]
                if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1 }
                if depth > 0 { pos = output.index(after: pos) }
            }
            if depth == 0 {
                result += String(output[searchStart..<markerRange.lowerBound])
                searchStart = output.index(after: pos)
            } else {
                result += String(output[searchStart..<markerRange.upperBound])
                searchStart = markerRange.upperBound
            }
        }
        result += String(output[searchStart...])
        return result
    }

    private static let stripPatterns = [
        #"(?is)<tool_call>\s*.*?\s*</tool_call>"#,
        #"(?is)<tool_code>\s*.*?\s*</tool_code>"#,
        #"(?is)<minimax:tool_call>\s*.*?\s*</minimax:tool_call>"#,
        #"(?is)<invoke\s+name=\"[^\"]+\"\s*>.*?</invoke>"#,
        #"(?is)<tool\s+name=\"[^\"]+\"\s*>.*?</tool>"#,
        #"(?is)</?arg\s+name=\"[^\"]+\">"#,
        #"(?is)</?parameter\s+name=\"[^\"]+\">"#,
        #"(?is)</?param\s+name=\"[^\"]+\">"#,
        #"(?is)<function=[^\s>]+>\s*|</function>"#,
        #"(?is)<parameter=[^\s>]+>\s*|</parameter>"#,
        #"</?tool_call[^>]*>"#,
        #"<\|tool_call>"#,
        #"</?tool_code[^>]*>"#,
        #"</?invoke[^>]*>"#,
        #"</?tool[^>]*>"#,
        #"(?is)```tool\s*\n.*?\n```"#,
        #"(?is)<\s*\w+\s*\(.*?\)>"#,
        #"(?m)^\s*\w+\s*\(.*?\)\s*$"#,
        // Legacy arg_key/arg_value pairs (old ChatPromptBuilder format)
        #"(?is)<arg_key>\s*.*?\s*</arg_key>"#,
        #"(?is)<arg_value>\s*.*?\s*</arg_value>"#,
        // Gemma 4 channel/turn/token markers
        #"<\|channel>"#,
        #"<channel\|>"#,
        #"<\|tool>"#,
        #"<tool\|>"#,
        #"<\|tool_response>"#,
        #"<tool_response\|>"#,
        #"<\|turn>"#,
        #"<turn\|>"#,
        #"<\|think\|>"#,
        #"<\|"\|>"#,
        #"(?is)<\|tool_calls\|>.*?</\|tool_calls\|>"#,
        #"(?is)<start_function_call>\s*.*?\s*<end_function_call>"#,
        // Pipe-delimited tool call format: tool_name|{json}
        #"[a-z_]+\|[\[{][^}\]]*[\]}]"#,
        // Leading bare JSON tool-call envelopes
        #"^\s*\{\s*"tool_calls"\s*:"#,
        #"^\s*\{\s*"name"\s*:\s*"[^"]+"\s*,"#,
    ]
}
