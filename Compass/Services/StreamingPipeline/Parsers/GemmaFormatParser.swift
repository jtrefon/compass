import Foundation

/// Gemma 4 format: `call:name{key:value,str:<|"|>text<|"|>}`
///
/// This is the SINGLE implementation of the Gemma parser — replaces the
/// 5 scattered implementations across ToolCallFallbackParser,
/// NativeMLXGenerator, ChatPromptBuilder, and vendor code.
public struct GemmaFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "gemma"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let marker = "call:"
        var calls: [RawToolCall] = []
        var searchStart = text.startIndex

        while let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
            let afterMarker = markerRange.upperBound
            var nameEnd = afterMarker
            while nameEnd < text.endIndex,
                  text[nameEnd].isLetter || text[nameEnd].isNumber || text[nameEnd] == "_" {
                nameEnd = text.index(after: nameEnd)
            }
            guard nameEnd > afterMarker else {
                searchStart = markerRange.upperBound
                continue
            }

            let name = String(text[afterMarker..<nameEnd])
            var braceStart = nameEnd
            while braceStart < text.endIndex, text[braceStart].isWhitespace {
                braceStart = text.index(after: braceStart)
            }
            guard braceStart < text.endIndex, text[braceStart] == "{" else {
                searchStart = nameEnd
                continue
            }

            var depth = 1
            var pos = text.index(after: braceStart)
            while pos < text.endIndex, depth > 0 {
                let ch = text[pos]
                if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1 }
                if depth > 0 { pos = text.index(after: pos) }
            }
            guard depth == 0 else {
                searchStart = nameEnd
                continue
            }

            let argsText = String(text[text.index(after: braceStart)..<pos])
            let cleanedArgs = argsText.replacingOccurrences(of: "<|\"|>", with: "\"")
            let jsonText = "{\(cleanedArgs)}"
            let args = parseJSON(text: jsonText) ?? parseFallback(text: cleanedArgs)
            let normalizedName = ToolAliasRegistry.shared.canonicalName(for: name)
            calls.append(RawToolCall(name: normalizedName, arguments: args))
            searchStart = text.index(after: pos)
        }

        return (calls, calls.isEmpty ? text : "")
    }

    private func parseJSON(text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let result = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: result, encoding: .utf8) else { return nil }
        return json
    }

    private func parseFallback(text: String) -> String {
        // Key:value pairs with comma separators
        let stripped = text.replacingOccurrences(of: "\"", with: "")
        let pairPattern = #"(\w+):(.*?)(?:,\s*\w+|$)"#
        guard let regex = try? NSRegularExpression(pattern: pairPattern, options: [.dotMatchesLineSeparators]) else {
            return "{}"
        }
        let nsRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        var dict: [String: String] = [:]
        for match in regex.matches(in: stripped, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: stripped),
                  let valR = Range(match.range(at: 2), in: stripped) else { continue }
            dict[String(stripped[keyR])] = String(stripped[valR]).trimmingCharacters(in: .whitespaces)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
