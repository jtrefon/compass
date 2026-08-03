import Foundation

public struct Symbol: Codable, Sendable {
    public let id: String
    public let resourceId: String
    public let name: String
    public let kind: SymbolKind
    public let lineStart: Int
    public let lineEnd: Int
    public let description: String?

    public init(id: String, resourceId: String, name: String, kind: SymbolKind, lineStart: Int, lineEnd: Int, description: String? = nil) {
        self.id = id
        self.resourceId = resourceId
        self.name = name
        self.kind = kind
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.description = description
    }
}
