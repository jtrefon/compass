import Foundation

public enum SymbolKind: String, Codable, Sendable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case variable
    case initializer
    case unknown
}
