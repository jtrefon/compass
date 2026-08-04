import Foundation

public protocol VectorIndex: AnyObject, Sendable {
    var count: Int { get }
    var dimensions: Int { get }

    func add(id: Int64, vector: [Float]) throws
    func addBatch(ids: [Int64], vectors: [[Float]]) throws

    func search(query: [Float], limit: Int) throws -> [(id: Int64, score: Float)]

    func remove(ids: [Int64]) throws

    func save(to path: String) throws
    func load(from path: String) throws

    func reset() throws
}
