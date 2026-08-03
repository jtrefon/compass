import Foundation

/// A partially or fully parsed tool call from textual model output.
public struct RawToolCall: Sendable {
    public let id: String
    public let name: String
    public let arguments: String  // Raw JSON argument string

    public init(id: String = UUID().uuidString, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One parser per tool-call wire format (SRP).
///
/// Each concrete parser handles exactly one format family and nothing else.
/// Parsers are stateless (except for optional end-of-stream buffering).
/// They can be called incrementally with partial input.
public protocol ToolCallFormatParser: Sendable {
    /// Unique identifier for debugging and telemetry.
    var formatIdentifier: String { get }

    /// Parse `text` and return any tool calls found, along with the
    /// remaining unparsed text.
    ///
    /// - Parameter text: Raw text to scan for tool-call markup.
    /// - Returns: Parsed tool calls and the leftover text.
    func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String)

    /// Called when the stream ends. Returns any buffered partial matches.
    func finalize() -> [RawToolCall]
}

// MARK: - Default implementations

extension ToolCallFormatParser {
    public func finalize() -> [RawToolCall] { [] }

    /// Decodes the HTML entities models commonly emit in tool-call markup
    /// (e.g. `&quot;` inside an attribute whose value is JSON).
    ///
    /// Deterministic: the mapping is an ordered array (a Dictionary literal
    /// iterates in hash order, which made `&amp;lt;` decode nondeterministically)
    /// and numeric entities (`&#x27;`, `&#34;`) are handled.
    nonisolated public func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        let named: [(String, String)] = [
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&amp;", "&"),
        ]
        for (entity, decoded) in named {
            result = result.replacingOccurrences(of: entity, with: decoded)
        }
        // Numeric entities: &#NN; and &#xHH;
        if result.contains("&#") {
            result = Self.decodeNumericEntities(result)
        }
        return result
    }

    private nonisolated static func decodeNumericEntities(_ value: String) -> String {
        let pattern = #"&#(x?)([0-9a-fA-F]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        var result = value
        for match in regex.matches(in: value, options: [], range: nsRange).reversed() {
            guard let full = Range(match.range(at: 0), in: value),
                  let body = Range(match.range(at: 1), in: value),
                  let digits = Range(match.range(at: 2), in: value) else { continue }
            let isHex = String(value[body]).lowercased() == "x"
            let radix: Int = isHex ? 16 : 10
            guard let scalarValue = Int(String(value[digits]), radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            result.replaceSubrange(full, with: String(scalar))
        }
        return result
    }
}
