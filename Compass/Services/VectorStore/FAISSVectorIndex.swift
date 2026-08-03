import Foundation

public final class FAISSVectorIndex: VectorIndex, @unchecked Sendable {
    public private(set) var count: Int = 0
    public let dimensions: Int

    private let factoryString: String
    private var index: FAISSIndexRef?
    private let queue: DispatchQueue

    public init(
        dimensions: Int,
        factoryString: String = "IDMap,Flat"
    ) {
        self.dimensions = dimensions
        self.factoryString = factoryString
        self.queue = DispatchQueue(
            label: "com.vectorstore.faiss.\(UUID().uuidString)",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    deinit {
        if let idx = index {
            vs_index_free(idx)
        }
    }

    // MARK: - Lifecycle

    private func ensureIndex() throws -> FAISSIndexRef {
        if let existing = index { return existing }
        return try createIndex()
    }

    private func createIndex() throws -> FAISSIndexRef {
        var raw: FAISSIndexRef?
        let code = vs_index_create(&raw, Int32(dimensions), factoryString, 0)
        guard code == 0, let idx = raw else {
            throw faissError("vs_index_create failed")
        }
        index = idx
        count = Int(vs_index_count(idx))
        return idx
    }

    private func close() {
        if let idx = index {
            vs_index_free(idx)
            index = nil
        }
        count = 0
    }

    // MARK: - Add

    public func add(id: Int64, vector: [Float]) throws {
        guard !vector.isEmpty else { throw VectorStoreError.emptyVector }
        guard vector.count == dimensions else {
            throw VectorStoreError.invalidDimension(expected: dimensions, got: vector.count)
        }
        let idx = try ensureIndex()
        var faissId = id
        let code = vector.withUnsafeBufferPointer { vecPtr in
            withUnsafeMutablePointer(to: &faissId) { idPtr in
                vs_index_add_with_ids(idx, 1, vecPtr.baseAddress, idPtr)
            }
        }
        guard code == 0 else { throw faissError("vs_index_add_with_ids failed") }
        count = Int(vs_index_count(idx))
    }

    public func addBatch(ids: [Int64], vectors: [[Float]]) throws {
        guard ids.count == vectors.count else {
            throw VectorStoreError.faissError("ids/vectors count mismatch")
        }
        guard !ids.isEmpty else { return }
        let idx = try ensureIndex()
        let flat = vectors.flatMap { $0 }
        let code = flat.withUnsafeBufferPointer { vecBuf in
            ids.withUnsafeBufferPointer { idBuf in
                vs_index_add_with_ids(idx, Int64(ids.count), vecBuf.baseAddress, idBuf.baseAddress)
            }
        }
        guard code == 0 else { throw faissError("vs_index_add_with_ids batch failed") }
        count = Int(vs_index_count(idx))
    }

    // MARK: - Search

    public func search(query: [Float], limit: Int) throws -> [(id: Int64, score: Float)] {
        guard !query.isEmpty else { return [] }
        guard query.count == dimensions else {
            throw VectorStoreError.invalidDimension(expected: dimensions, got: query.count)
        }
        let idx = try ensureIndex()
        let neighbors = min(limit, max(count, 1))
        var distances = [Float](repeating: 0, count: neighbors)
        var labels = [Int64](repeating: -1, count: neighbors)
        let code = query.withUnsafeBufferPointer { qBuf in
            distances.withUnsafeMutableBufferPointer { dBuf in
                labels.withUnsafeMutableBufferPointer { lBuf in
                    vs_index_search(idx, 1, qBuf.baseAddress, Int64(neighbors), dBuf.baseAddress, lBuf.baseAddress)
                }
            }
        }
        guard code == 0 else { throw faissError("vs_index_search failed") }
        return zip(labels, distances).filter { $0.0 >= 0 }.map { ($0.0, $0.1) }
    }

    // MARK: - Remove

    public func remove(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let idx = try ensureIndex()
        let code = ids.withUnsafeBufferPointer { idBuf in
            vs_index_remove_ids(idx, idBuf.baseAddress, ids.count)
        }
        guard code == 0 else { throw faissError("vs_index_remove_ids failed") }
        count = Int(vs_index_count(idx))
    }

    // MARK: - Persistence

    public func save(to path: String) throws {
        let idx = try ensureIndex()
        let code = vs_index_save(idx, path)
        guard code == 0 else { throw faissError("vs_index_save failed") }
    }

    public func load(from path: String) throws {
        close()
        var raw: FAISSIndexRef?
        let code = vs_index_load(path, &raw)
        guard code == 0, let idx = raw else {
            throw faissError("vs_index_load failed")
        }
        index = idx
        count = Int(vs_index_count(idx))
    }

    public func reset() throws {
        let idx = try ensureIndex()
        let code = vs_index_reset(idx)
        guard code == 0 else { throw faissError("vs_index_reset failed") }
        count = 0
    }

    // MARK: - Helpers

    private func faissError(_ context: String) -> VectorStoreError {
        let msg = String(cString: vs_last_error())
        return .faissError("\(context): \(msg)")
    }
}
