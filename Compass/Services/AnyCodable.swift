import Foundation

// Helper for encoding heterogeneous types
internal struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        if try encodePrimitive(into: encoder) { return }
        if try encodeDictionary(into: encoder) { return }
        if try encodeArray(into: encoder) { return }

        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }

    private func encodePrimitive(into encoder: Encoder) throws -> Bool {
        var container = encoder.singleValueContainer()

        if let val = value as? String {
            try container.encode(val)
            return true
        }
        if let val = value as? Int {
            try container.encode(val)
            return true
        }
        if let val = value as? Double {
            try container.encode(val)
            return true
        }
        if let val = value as? Bool {
            try container.encode(val)
            return true
        }

        return false
    }

    private func encodeDictionary(into encoder: Encoder) throws -> Bool {
        guard let val = value as? [String: Any] else { return false }
        var mapContainer = encoder.container(keyedBy: AnyCodableDynamicKey.self)
        for (key, nestedValue) in val {
            try mapContainer.encode(AnyCodable(nestedValue), forKey: AnyCodableDynamicKey(stringValue: key)!)
        }
        return true
    }

    private func encodeArray(into encoder: Encoder) throws -> Bool {
        guard let val = value as? [Any] else { return false }
        var arrContainer = encoder.unkeyedContainer()
        for nestedValue in val {
            try arrContainer.encode(AnyCodable(nestedValue))
        }
        return true
    }
}
