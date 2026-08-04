import Foundation

public protocol MemoryEmbeddingGenerating: Sendable {
    var modelIdentifier: String { get }
    func generateEmbedding(for text: String) async throws -> [Float]
}

public struct NullEmbeddingGenerator: MemoryEmbeddingGenerating {
    public let modelIdentifier: String = "null"
    public init() {}
    public func generateEmbedding(for text: String) async throws -> [Float] {
        []
    }
}
