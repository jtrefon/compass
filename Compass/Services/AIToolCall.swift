import Foundation

public struct AIToolCall: Codable, @unchecked Sendable {
    public let id: String
    public let type: String
    public let name: String
    public let arguments: [String: Any]

    public enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

    public enum FunctionCodingKeys: String, CodingKey {
        case name
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        type = (try? container.decode(String.self, forKey: .type)) ?? "function"

        let functionContainer = try container.nestedContainer(keyedBy: FunctionCodingKeys.self, forKey: .function)
        name = try functionContainer.decode(String.self, forKey: .name)

        arguments = Self.decodeArguments(from: functionContainer, toolName: name)
    }

    init(id: String, name: String, arguments: [String: Any]) {
        self.id = id
        self.type = "function"
        self.name = name
        self.arguments = arguments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)

        var functionContainer = container.nestedContainer(keyedBy: FunctionCodingKeys.self, forKey: .function)
        try functionContainer.encode(name, forKey: .name)

        let jsonData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        try functionContainer.encode(jsonString, forKey: .arguments)
    }

    private static func decodeArguments(
        from container: KeyedDecodingContainer<FunctionCodingKeys>,
        toolName: String
    ) -> [String: Any] {
        if let argumentsString = try? container.decode(String.self, forKey: .arguments) {
            if let dict = parseJSONObjectString(argumentsString) {
                return dict
            }
            if let array = parseJSONArrayString(argumentsString),
               toolName == "write_files" {
                let fileEntries = array.compactMap { $0 as? [String: Any] }
                if !fileEntries.isEmpty {
                    return ["files": fileEntries]
                }
            }
            let trimmed = argumentsString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [:] : ["_raw_args_chunk": argumentsString]
        }

        if let jsonValue = try? container.decode(DecodableJSON.self, forKey: .arguments) {
            let object = jsonValue.foundationObject()
            if let dict = object as? [String: Any] {
                return dict
            }
            if let array = object as? [Any], toolName == "write_files" {
                let fileEntries = array.compactMap { $0 as? [String: Any] }
                if !fileEntries.isEmpty {
                    return ["files": fileEntries]
                }
            }
            if let serialized = jsonValue.jsonString(),
               !serialized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ["_raw_args_chunk": serialized]
            }
        }

        return [:]
    }

    private static func parseJSONObjectString(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func parseJSONArrayString(_ raw: String) -> [Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [Any] else {
            return nil
        }
        return array
    }
}
