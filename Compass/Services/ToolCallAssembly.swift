import Foundation

/// Outcome of assembling model/emitted tool calls.
///
/// Streamed tool-call arguments can arrive fragmented or malformed. We must
/// never dispatch a tool call whose arguments failed to parse (that produced
/// the `_raw_args_chunk` bug). Instead, valid calls are separated from
/// malformed ones so the engine can recover (synthetic failed tool message).
struct AssembledToolCalls: Sendable {
    let valid: [AIToolCall]
    let malformed: [MalformedToolCall]
}

/// A tool call the model emitted whose arguments could not be parsed into a
/// valid JSON object.
public struct MalformedToolCall: Sendable {
    public let id: String
    public let name: String
    public let rawArguments: String
    public let error: String
}

enum ToolArgumentParseError: Error, Sendable {
    case invalidJSON(String)
}

/// A single streamed/structured tool-call draft before argument parsing.
struct ToolArgumentDraft: Sendable {
    let id: String
    let name: String
    let arguments: String
}

/// Pure, testable tool-call argument assembly. Extracted from `ChunkCollector`
/// so the corruption logic (`_raw_args_chunk` removal, malformed separation)
/// can be unit-tested without constructing the streaming service.
enum ToolArgumentParser {
    /// Parses a streamed arguments string into a JSON object.
    /// - Returns `.failure` for non-object or truncated JSON. We never fabricate
    ///   JSON by wrapping arbitrary text in braces.
    static func parse(_ raw: String) -> Result<[String: Any], ToolArgumentParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success([:]) }
        guard let object = parseJSONObject(trimmed) else {
            return .failure(.invalidJSON(trimmed))
        }
        return .success(object)
    }

    /// Splits drafts into valid vs malformed calls based on argument parsing.
    static func assemble(_ drafts: [ToolArgumentDraft]) -> AssembledToolCalls {
        var valid: [AIToolCall] = []
        var malformed: [MalformedToolCall] = []
        for draft in drafts {
            let trimmed = draft.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "{}" {
                valid.append(AIToolCall(id: draft.id, name: draft.name, arguments: [:]))
                continue
            }
            switch parse(draft.arguments) {
            case .success(let args):
                valid.append(AIToolCall(id: draft.id, name: draft.name, arguments: args))
            case .failure(let error):
                malformed.append(MalformedToolCall(
                    id: draft.id,
                    name: draft.name,
                    rawArguments: draft.arguments,
                    error: "\(error)"
                ))
            }
        }
        return AssembledToolCalls(valid: valid, malformed: malformed)
    }

    private static func parseJSONObject(_ candidate: String) -> [String: Any]? {
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }
}
