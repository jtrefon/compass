import Foundation

/// Structured XML: `<tool_call><tool name="..."><arg name="k">v</arg></tool></tool_call>`
/// Also handles `<function=name>...<parameter=key>value</parameter></function>` blocks.
public struct XMLToolCallFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "xml"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let outerPattern = #"(?is)<tool_call\s*/>|<tool_call>\s*(.*?)\s*</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: outerPattern) else { return ([], text) }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return ([], text) }

        var calls: [RawToolCall] = []
        var lastEnd = text.startIndex

        for match in matches {
            guard match.numberOfRanges >= 2,
                  let bodyRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range(at: 0), in: text) else { continue }

            // Track text between matches as remaining
            let between = String(text[lastEnd..<fullRange.lowerBound])
            lastEnd = fullRange.upperBound

            let body = String(text[bodyRange])
            calls.append(contentsOf: extractToolCall(from: body))
        }

        let remaining = String(text[lastEnd...])
        return (calls, remaining)
    }

    private func extractToolCall(from body: String) -> [RawToolCall] {
        let patterns = [
            // Self-closing: <tool name="x" path="y" ... />
            #"(?is)<tool\s+name=\"([^\"]+)\"([^>]*?)/\s*>"#,
            #"(?is)<tool\s+name=\"([^\"]+)\"\s*>(.*?)</tool>"#,
            #"(?is)<function=([^\s>]+)>\s*(.*?)\s*</function>"#,
        ]
        let argPatterns = [
            #"(?is)<arg\s+name=\"([^\"]+)\"\s*>(.*?)</arg>"#,
            #"(?is)<parameter\s+name=\"([^\"]+)\"\s*>(.*?)</parameter>"#,
            #"(?is)<parameter=([^\s>]+)>\s*(.*?)\s*</parameter>"#,
        ]

        var calls: [RawToolCall] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)
            let matches = regex.matches(in: body, options: [], range: nsRange)
            for match in matches where match.numberOfRanges >= 3 {
                guard let nameR = Range(match.range(at: 1), in: body) else { continue }
                let name = normalizeName(String(body[nameR]))
                guard !name.isEmpty else { continue }
                let rawArgs: String
                if pattern.contains("/\\s*>") {
                    // self-closing: attributes on the tag itself
                    guard let attrsR = Range(match.range(at: 2), in: body) else { continue }
                    rawArgs = String(body[attrsR])
                } else {
                    guard let toolBodyR = Range(match.range(at: 2), in: body) else { continue }
                    rawArgs = String(body[toolBodyR])
                }
                let args: [String: String]
                if pattern.contains("/\\s*>") {
                    args = extractInlineAttributes(from: rawArgs)
                } else {
                    args = extractArguments(from: rawArgs, patterns: argPatterns)
                }
                let jsonArgs = dictToJSON(args) ?? "{}"
                calls.append(RawToolCall(name: name, arguments: jsonArgs))
            }
            if !calls.isEmpty { return calls }
        }
        return calls
    }

    /// Parses `key="value"` attributes from a self-closing tool tag.
    private func extractInlineAttributes(from text: String) -> [String: String] {
        let pattern = #"([a-zA-Z_][a-zA-Z0-9_\-]*)=\"(.*?)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var args: [String: String] = [:]
        for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: text),
                  let valR = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyR])
            if key == "name" { continue }
            args[key] = decodeHTMLEntities(String(text[valR]))
        }
        return args
    }

    private func extractArguments(from text: String, patterns: [String]) -> [String: String] {
        var args: [String: String] = [:]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
                guard let keyR = Range(match.range(at: 1), in: text),
                      let valR = Range(match.range(at: 2), in: text) else { continue }
                let key = String(text[keyR]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = decodeHTMLEntities(String(text[valR]).trimmingCharacters(in: .whitespacesAndNewlines))
                if !key.isEmpty { args[key] = val }
            }
        }
        return args
    }

    private func normalizeName(_ raw: String) -> String {
        ParserHelper.normalizeName(raw)
    }

    private func dictToJSON(_ dict: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
