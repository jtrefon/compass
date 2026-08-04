import Foundation

/// Bare `<function=name><parameter=key>value</parameter></function>` format.
public struct BareFunctionFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "bare_function"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let pattern = #"(?is)<function=([^\s>]+)>\s*(.*?)\s*</function>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], text) }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return ([], text) }

        var calls: [RawToolCall] = []
        var lastEnd = text.startIndex

        for match in matches where match.numberOfRanges >= 3 {
            guard let nameR = Range(match.range(at: 1), in: text),
                  let bodyR = Range(match.range(at: 2), in: text),
                  let fullR = Range(match.range(at: 0), in: text) else { continue }
            lastEnd = fullR.upperBound

            let name = ToolAliasRegistry.shared.canonicalName(for: String(text[nameR]))
            let body = String(text[bodyR])
            let paramPattern = #"(?is)<parameter=([^\s>]+)>\s*(.*?)\s*</parameter>"#
            let namedPattern = #"(?is)<parameter\s+name=\"([^\"]+)\"\s*>(.*?)</parameter>"#
            var dict = extractArgs(from: body, pattern: paramPattern)
            if dict.isEmpty { dict = extractArgs(from: body, pattern: namedPattern) }
            let json = dictToJSON(dict)
            calls.append(RawToolCall(name: name, arguments: json))
        }

        return (calls, String(text[lastEnd...]))
    }

    private func extractArgs(from text: String, pattern: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var dict: [String: String] = [:]
        for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: text),
                  let valR = Range(match.range(at: 2), in: text) else { continue }
            dict[String(text[keyR])] = String(text[valR])
        }
        return dict
    }

    private func dictToJSON(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
