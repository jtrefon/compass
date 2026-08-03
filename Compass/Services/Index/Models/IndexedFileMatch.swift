import Foundation

public struct IndexedFileMatch: Sendable {
    public let path: String
    public let aiEnriched: Bool
    public let qualityScore: Double?
}
