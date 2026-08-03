import Foundation

/// Legacy `<tool_code>tool_name<param name="k">v</param></tool_code>` format.
public struct LegacyToolCodeFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "legacy_tool_code"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let pattern = #"(?is)<tool_code>\s*(.*?)\s*</tool_code>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], text) }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return ([], text) }

        var calls: [RawToolCall] = []
        var lastEnd = text.startIndex

        for match in matches {
            guard match.numberOfRanges >= 2,
                  let bodyRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range(at: 0), in: text) else { continue }
            lastEnd = fullRange.upperBound

            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = extractCall(from: body) {
                calls.append(call)
            }
        }

        return (calls, String(text[lastEnd...]))
    }

    private func extractCall(from body: String) -> RawToolCall? {
        // Self-closing: <tool name="x" attr="val"/>
        let selfClosingPattern = #"(?is)<tool\s+name=\"([^\"]+)\"(.*?)/>\s*"#
        if let selfRegex = try? NSRegularExpression(pattern: selfClosingPattern) {
            let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)
            if let match = selfRegex.firstMatch(in: body, options: [], range: nsRange),
               match.numberOfRanges >= 3,
               let nameR = Range(match.range(at: 1), in: body),
               let attrR = Range(match.range(at: 2), in: body) {
                let name = normalizeName(String(body[nameR]))
                let attrs = extractInlineAttributes(from: String(body[attrR]))
                return RawToolCall(name: name, arguments: attrs)
            }
        }

        // Standard: tool name is text before the first `<` tag or whitespace
        let toolName: String
        if let tagStart = body.firstIndex(of: "<") {
            toolName = String(body[..<tagStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let space = body.firstIndex(of: " ") {
            toolName = String(body[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            toolName = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = normalizeName(toolName)
        guard !name.isEmpty else { return nil }

        let paramPattern = #"(?is)<param\s+name=\"([^\"]+)\"\s*>(.*?)</param>"#
        let args = extractPairs(from: body, pattern: paramPattern)
        return RawToolCall(name: name, arguments: args)
    }

    private func extractInlineAttributes(from text: String) -> String {
        let pattern = #"([a-zA-Z_][a-zA-Z0-9_\-]*)=\"(.*?)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "{}" }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var dict: [String: String] = [:]
        for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: text),
                  let valR = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyR])
            if key == "name" { continue }
            dict[key] = decodeHTMLEntities(String(text[valR]))
        }
        return jsonString(from: dict)
    }

    private func extractPairs(from text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "{}" }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var dict: [String: String] = [:]
        for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: text),
                  let valR = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyR]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = decodeHTMLEntities(String(text[valR]).trimmingCharacters(in: .whitespacesAndNewlines))
            if !key.isEmpty { dict[key] = val }
        }
        return jsonString(from: dict)
    }

    private func normalizeName(_ raw: String) -> String {
        ParserHelper.normalizeName(raw)
    }

    private func jsonString(from dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
