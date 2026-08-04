import Foundation

public enum LogValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: LogValue])
    case array([LogValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let decodedString = try? container.decode(String.self) { self = .string(decodedString); return }
        if let decodedInt = try? container.decode(Int.self) { self = .int(decodedInt); return }
        if let decodedDouble = try? container.decode(Double.self) { self = .double(decodedDouble); return }
        if let decodedBool = try? container.decode(Bool.self) { self = .bool(decodedBool); return }
        if let decodedObject = try? container.decode([String: LogValue].self) { self = .object(decodedObject); return }
        if let decodedArray = try? container.decode([LogValue].self) { self = .array(decodedArray); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let stringValue):
            try container.encode(stringValue)
        case .int(let intValue):
            try container.encode(intValue)
        case .double(let doubleValue):
            try container.encode(doubleValue)
        case .bool(let boolValue):
            try container.encode(boolValue)
        case .object(let objectValue):
            try container.encode(objectValue)
        case .array(let arrayValue):
            try container.encode(arrayValue)
        case .null:
            try container.encodeNil()
        }
    }

    public static func from(_ value: Any) -> LogValue {
        switch value {
        case let stringValue as String:
            return .string(stringValue)
        case let intValue as Int:
            return .int(intValue)
        case let doubleValue as Double:
            return .double(doubleValue)
        case let boolValue as Bool:
            return .bool(boolValue)
        case let objectValue as [String: Any]:
            return .object(objectValue.mapValues { LogValue.from($0) })
        case let arrayValue as [Any]:
            return .array(arrayValue.map { LogValue.from($0) })
        default:
            return .null
        }
    }
}
