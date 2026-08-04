import Foundation

enum ParserHelper {
    static func normalizeName(_ rawName: String) -> String {
        let decoded = Self.decodeHTMLEntities(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolAliasRegistry.shared.canonicalName(for: decoded)
    }

    static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func recoverArguments(in body: String, range: NSRange, regex: NSRegularExpression) -> [String: Any] {
        let parameters = regex.matches(in: body, options: [], range: range)
        var arguments: [String: Any] = [:]
        for parameter in parameters {
            guard parameter.numberOfRanges == 3,
                  let nameRange = Range(parameter.range(at: 1), in: body),
                  let valueRange = Range(parameter.range(at: 2), in: body) else { continue }
            let name = decodeHTMLEntities(String(body[nameRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let value = decodeHTMLEntities(String(body[valueRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            arguments[name] = value
        }
        return arguments
    }
}
