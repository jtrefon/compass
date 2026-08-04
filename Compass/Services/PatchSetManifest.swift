import Foundation

public struct PatchSetManifest: Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public var entries: [PatchSetEntry]

    public init(id: String, createdAt: Date, entries: [PatchSetEntry]) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
    }
}
