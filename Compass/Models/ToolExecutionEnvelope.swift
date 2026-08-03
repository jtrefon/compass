import Foundation

/// First-line execution envelope for a tool result.
///
/// Serialization is a **logfmt-style first line** inside brackets — e.g.
/// `[tool=file_read param.path=src/app/global.css status=success]` — followed by
/// the existing structured JSON body. The first line is what the model reads to
/// confirm what ran (and to avoid re-issuing an identical call); the JSON body is
/// what the UI/snapshot consumers parse via `decode(from:)`.
///
/// Field names align with OpenTelemetry GenAI conventions so the envelope can later be
/// exported as `gen_ai.tool.*` span events without churn:
/// `tool` -> `gen_ai.tool.name`, `params` -> `gen_ai.tool.call.arguments`,
/// `status` -> `gen_ai.response.finish_reasons`.
struct ToolExecutionEnvelope: Codable, Sendable {
    let status: ToolExecutionStatus
    let message: String
    let payload: String?
    let preview: String?
    let toolName: String
    let toolCallId: String
    let targetFile: String?
    let argumentKeys: [String]?
    let argumentPreview: String?
    let recoveryHint: String?
    /// Normalized per-argument identity, e.g. `["path": "src/app/global.css"]`.
    /// Drives the anti-repeat rule and maps to `gen_ai.tool.call.arguments`.
    let params: [String: String]?

    /// The compact, model-facing first line, e.g.
    /// `[tool=file_read param.path=src/app/global.css status=success]`
    func firstLine() -> String {
        var parts = ["tool=\(toolName)", "status=\(status.rawValue)"]
        if let params {
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                var val = value
                if val.count > 200 { val = String(val.prefix(200)) + "…" }
                if val.contains(" ") || val.contains("=") || val.contains("\"") {
                    val = "\"\(val)\""
                }
                parts.append("param.\(key)=\(val)")
            }
        }
        return "[" + parts.joined(separator: " ") + "]"
    }

    /// Content stored on the `ChatMessage`. First line is the logfmt envelope; the
    /// remainder is the structured JSON body that `decode(from:)` reads.
    func encodedString() -> String {
        let json: String = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self),
                  let string = String(data: data, encoding: .utf8) else {
                let fallback: [String: Any] = [
                    "status": status.rawValue,
                    "message": message,
                    "preview": preview ?? "",
                    "toolName": toolName,
                    "toolCallId": toolCallId,
                    "targetFile": targetFile ?? "",
                    "argumentKeys": argumentKeys ?? [],
                    "argumentPreview": argumentPreview ?? "",
                    "recoveryHint": recoveryHint ?? "",
                    "params": params ?? [:]
                ]
                return (try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"status\":\"\(status.rawValue)\",\"message\":\"\(message)\"}"
            }
            return string
        }()
        return firstLine() + "\n" + json
    }

    private static let envelopeLineRegex = #"^\s*\[[^\]]*\]\s*\n"#

    static func decode(from content: String) -> ToolExecutionEnvelope? {
        // Strip a leading logfmt envelope line (if present) before JSON decoding,
        // so the structured body is parsed exactly as before.
        let body: String
        if let range = content.range(of: envelopeLineRegex, options: .regularExpression) {
            body = String(content[range.upperBound...])
        } else {
            body = content
        }
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolExecutionEnvelope.self, from: data)
    }

    /// Extract just the logfmt first-line envelope from a message body, if present.
    static func firstLine(from content: String) -> String? {
        guard let range = content.range(of: envelopeLineRegex, options: .regularExpression) else {
            return nil
        }
        return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Produce model-facing content: first-line envelope + the actual output (payload).
    /// Strips the JSON metadata blob that system parsers use but confuses the model.
    static func modelFacingContent(from fullContent: String) -> String {
        guard let range = fullContent.range(of: envelopeLineRegex, options: .regularExpression) else {
            return fullContent
        }
        let envelopeLine = fullContent[range].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = fullContent[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract the payload field from the JSON body
        if let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(ToolExecutionEnvelope.self, from: data),
           let payload = envelope.payload, !payload.isEmpty {
            return envelopeLine + "\n" + payload
        }
        // For failed tools or when payload is empty, show the message
        if let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(ToolExecutionEnvelope.self, from: data),
           !envelope.message.isEmpty {
            return envelopeLine + "\n" + envelope.message
        }
        // Fallback: just the envelope line (no payload visible)
        return envelopeLine + "\n(tool output not available)"
    }
}
