import Foundation

/// CodingKey for JSON payloads with dynamic (model-defined) keys.
struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Decodes an arbitrary JSON value into a Swift enum tree, preserving type
/// information so it can be re-encoded losslessly (used for tool-call
/// arguments and provider response payloads).
enum DecodableJSON: Decodable {
    case object([String: DecodableJSON])
    case array([DecodableJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var dict: [String: DecodableJSON] = [:]
            for key in container.allKeys {
                dict[key.stringValue] = try container.decode(DecodableJSON.self, forKey: key)
            }
            self = .object(dict)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var values: [DecodableJSON] = []
            while !unkeyed.isAtEnd {
                values.append(try unkeyed.decode(DecodableJSON.self))
            }
            self = .array(values)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    func foundationObject() -> Any {
        switch self {
        case .object(let dict):
            return dict.mapValues { $0.foundationObject() }
        case .array(let values):
            return values.map { $0.foundationObject() }
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    func jsonString() -> String? {
        let object = foundationObject()
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
