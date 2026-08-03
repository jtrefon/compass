import Foundation

/// Parses tool calls from bare JSON: `{"name":"x","arguments":{...}}`
/// or JSON envelopes: `{"tool_calls":[{"name":"x","arguments":{...}}]}`,
/// including fenced code blocks: ```json ... ```.
public struct JSONToolCallFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "json"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        var remaining = text

        // 1. Extract fenced JSON blocks: ```json ... ``` or ``` ... ```
        if let (before, block, after) = extractFencedJSON(from: remaining) {
            if let calls = decodeCalls(from: block) {
                return (calls, before + after)
            }
            remaining = before + after
        }

        // 2. Scan for inline JSON objects within larger text
        if let (before, block, after) = extractFirstJSONObject(from: remaining) {
            if let calls = decodeCalls(from: block) {
                return (calls, before + after)
            }
            remaining = before + after
        }

        // 3. Try decoding the entire text as a single tool call or envelope
        if let calls = decodeCalls(from: remaining) {
            return (calls, "")
        }

        return ([], text)
    }

    // MARK: - Fenced JSON extraction

    private func extractFencedJSON(from text: String) -> (before: String, block: String, after: String)? {
        let fences = ["```json", "```"]
        for fence in fences {
            guard let open = text.range(of: fence) else { continue }
            let afterOpen = text[open.upperBound...]
            guard let close = afterOpen.range(of: "```") else { continue }
            let before = String(text[..<open.lowerBound])
            let block = String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(afterOpen[close.upperBound...])
            return (before, block, after)
        }
        return nil
    }

    // MARK: - Inline JSON extraction

    /// Finds the first balanced `{...}` JSON object in the text, handling string escapes.
    private func extractFirstJSONObject(from text: String) -> (before: String, block: String, after: String)? {
        guard let open = text.firstIndex(of: "{") else { return nil }
        let before = String(text[..<open])
        let afterOpen = text[open...]
        var depth = 0
        var i = afterOpen.startIndex
        var inString = false
        while i < afterOpen.endIndex {
            let ch = afterOpen[i]
            if ch == "\"" && (i == afterOpen.startIndex || afterOpen[afterOpen.index(before: i)] != "\\") {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1 }
            }
            if depth == 0 {
                let block = String(afterOpen[afterOpen.startIndex...i])
                let after = afterOpen.index(after: i) < afterOpen.endIndex
                    ? String(afterOpen[afterOpen.index(after: i)...])
                    : ""
                return (before, block, after)
            }
            i = afterOpen.index(after: i)
        }
        return nil
    }

    // MARK: - JSON decoding

    private func decodeCalls(from text: String) -> [RawToolCall]? {
        if let single = decodeSingle(from: text) {
            return [single]
        }
        if let envelope = decodeEnvelope(from: text), !envelope.isEmpty {
            return envelope
        }
        return nil
    }

    private func decodeSingle(from text: String) -> RawToolCall? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        let args: String
        if let argsObj = object["arguments"] {
            if let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: [.sortedKeys]),
               let argsString = String(data: argsData, encoding: .utf8) {
                args = argsString
            } else {
                args = "\(argsObj)"
            }
        } else {
            args = "{}"
        }
        return RawToolCall(name: ToolAliasRegistry.shared.canonicalName(for: name), arguments: args)
    }

    private func decodeEnvelope(from text: String) -> [RawToolCall]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCalls = object["tool_calls"] as? [[String: Any]] else { return nil }
        let calls = rawCalls.compactMap { raw -> RawToolCall? in
            guard let name = raw["name"] as? String else { return nil }
            let args: String
            if let argsObj = raw["arguments"] {
                if let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: [.sortedKeys]),
                   let argsString = String(data: argsData, encoding: .utf8) {
                    args = argsString
                } else {
                    args = "\(argsObj)"
                }
            } else {
                args = "{}"
            }
            return RawToolCall(name: ToolAliasRegistry.shared.canonicalName(for: name), arguments: args)
        }
        return calls.isEmpty ? nil : calls
    }
}
