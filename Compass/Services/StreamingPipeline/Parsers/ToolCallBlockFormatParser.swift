import Foundation

/// Block format: `<tool_call>/path\ncontent</tool_call>` → `write_file`
public struct ToolCallBlockFormatParser: ToolCallFormatParser {
    public let formatIdentifier = "tool_call_block"

    public init() {}

    public func parse(_ text: String) -> (toolCalls: [RawToolCall], remaining: String) {
        let parts = text.components(separatedBy: "<tool_call>")
        guard parts.count > 1 else { return ([], text) }

        var calls: [RawToolCall] = []
        var remaining = parts[0]

        for part in parts.dropFirst() {
            let body: String
            let after: String
            if let closeRange = part.range(of: "</tool_call>", options: [.caseInsensitive]) {
                body = String(part[..<closeRange.lowerBound])
                after = String(part[closeRange.upperBound...])
            } else {
                body = part
                after = ""
            }

            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { remaining += "<tool_call>" + part; continue }

            let lines = trimmed.components(separatedBy: "\n")
            guard lines.count >= 2 else { remaining += "<tool_call>" + part; continue }

            let path = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { remaining += "<tool_call>" + part; continue }

            let fileContent = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileContent.isEmpty else { remaining += "<tool_call>" + part; continue }

            let args: [String: String] = ["path": path, "content": fileContent]
            if let json = dictToJSON(args) {
                calls.append(RawToolCall(name: "write", arguments: json))
            }
            remaining += after
        }

        return (calls, remaining)
    }

    private func dictToJSON(_ dict: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
