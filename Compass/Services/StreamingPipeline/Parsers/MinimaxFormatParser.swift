import Foundation

/// MiniMax M2 format: `<invoke name="f"><parameter name="k">v</parameter></invoke>`
public struct MinimaxFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "minimax_m2"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let pattern = #"(?is)<invoke\s+name=\"([^\"]+)\"\s*>(.*?)</invoke>"#
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

            let name = normalizeName(String(text[nameR]))
            let body = String(text[bodyR])
            let paramPattern = #"(?is)<parameter\s+name=\"([^\"]+)\"\s*>(.*?)</parameter>"#
            let args = extractArgs(from: body, pattern: paramPattern)
            calls.append(RawToolCall(name: name, arguments: args))        }

        return (calls, String(text[lastEnd...]))
    }

    private func normalizeName(_ raw: String) -> String {
        ParserHelper.normalizeName(raw)
    }

    private func extractArgs(from text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "{}" }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var dict: [String: String] = [:]
        for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges >= 3 {
            guard let keyR = Range(match.range(at: 1), in: text),
                  let valR = Range(match.range(at: 2), in: text) else { continue }
            dict[String(text[keyR])] = String(text[valR])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
