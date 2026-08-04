import Foundation

/// Shared coercion of model-provided JSON argument values (Any) into
/// typed Swift values. JSON round-tripping can produce Double, Int, Int64,
/// NSNumber, or String depending on the parser — never assume one shape.
enum ToolArgumentCoercion {
    static func asDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as Int32:
            return Double(number)
        case let number as Int64:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func asBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
