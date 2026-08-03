import Foundation

private func vs_createDefaultIndex(dimensions: Int, factoryString: String) -> FAISSVectorIndex {
    FAISSVectorIndex(dimensions: dimensions, factoryString: factoryString)
}

public struct VectorSearchResult: Sendable, Identifiable {
    public let id: String
    public let score: Float
    public let metadata: VectorStoreMetadata.Entry?

    public init(id: String, score: Float, metadata: VectorStoreMetadata.Entry?) {
        self.id = id
        self.score = score
        self.metadata = metadata
    }
}

public actor VectorStoreService {
    private let index: any VectorIndex
    private var metadata: VectorStoreMetadata
    private var idMapping: [String: Int64]
    private var reverseMapping: [Int64: String]
    private var nextId: Int64
    private let config: VectorStoreConfiguration
    private var isLoaded: Bool

    public init(
        index: any VectorIndex,
        config: VectorStoreConfiguration
    ) {
        self.index = index
        self.config = config
        self.metadata = VectorStoreMetadata(
            fileURL: config.metadataFileURL,
            logsBaseURL: config.storePath
                .deletingLastPathComponent()
                .appendingPathComponent("logs")
        )
        self.idMapping = [:]
        self.reverseMapping = [:]
        self.nextId = 1
        self.isLoaded = false
    }

    public static func create(with config: VectorStoreConfiguration) -> VectorStoreService {
        let faissIndex = vs_createDefaultIndex(
            dimensions: config.dimensions,
            factoryString: config.factoryString
        )
        return VectorStoreService(index: faissIndex, config: config)
    }

    // MARK: - Lifecycle

    public func load() throws {
        try FileManager.default.createDirectory(
            at: config.storePath,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: config.indexFileURL.path) {
            try index.load(from: config.indexFileURL.path)
        }
        try metadata.load()
        if !restoreIDMappingsFromDisk() {
            // Legacy store without a persisted mapping: FAISS labels after
            // removals carry gaps that a sequential rebuild would misalign.
            // Rebuild is the best we can do without vector extraction, and
            // the corrected mapping is persisted immediately so every
            // subsequent load is exact.
            rebuildIDMappings()
            try persistIDMappings()
        }
        isLoaded = true
        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.load", data: [
                "entryCount": self.entryCount,
                "storePath": self.config.storePath.path
            ])
        }
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: config.storePath,
            withIntermediateDirectories: true
        )
        // Mapping FIRST: if the process dies mid-save, metadata+mapping stay
        // consistent (the restore guard then fails on count mismatch and
        // rebuilds) — the previous order (metadata then mapping) left a stale
        // mapping that silently misattributed results after a crash.
        try persistIDMappings()
        try metadata.save()
        try index.save(to: config.indexFileURL.path)
        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.save", data: [
                "entryCount": self.entryCount
            ])
        }
    }

    // MARK: - Add

    @discardableResult
    public func addEntry(
        text: String?,
        vector: [Float],
        source: String,
        category: String? = nil,
        id: String? = nil,
        sourceReference: SourceReference? = nil
    ) throws -> String {
        let entryId = id ?? UUID().uuidString
        let faissId = nextId
        nextId += 1

        try index.add(id: faissId, vector: vector)

        let entry = VectorStoreMetadata.Entry(
            id: entryId,
            text: text,
            source: source,
            category: category,
            embeddingModel: config.embeddingModel,
            sourceReference: sourceReference
        )
        metadata.add(entry)
        idMapping[entryId] = faissId
        reverseMapping[faissId] = entryId

        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.add_entry", data: [
                "entryId": entryId,
                "source": source,
                "textLength": text?.count ?? 0
            ])
        }
        return entryId
    }

    @discardableResult
    public func addBatch(
        entries: [(text: String?, vector: [Float], source: String, category: String?)]
    ) throws -> [String] {
        guard !entries.isEmpty else { return [] }

        var ids = [String]()
        var faissIds = [Int64]()
        var vectors = [[Float]]()

        for entry in entries {
            let entryId = UUID().uuidString
            let faissId = nextId
            nextId += 1

            ids.append(entryId)
            faissIds.append(faissId)
            vectors.append(entry.vector)

            let meta = VectorStoreMetadata.Entry(
                id: entryId,
                text: entry.text,
                source: entry.source,
                category: entry.category,
                embeddingModel: config.embeddingModel
            )
            metadata.add(meta)
            idMapping[entryId] = faissId
            reverseMapping[faissId] = entryId
        }

        try index.addBatch(ids: faissIds, vectors: vectors)

        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.add_batch", data: [
                "count": entries.count
            ])
        }
        return ids
    }

    // MARK: - Search

    public func search(
        queryVector: [Float],
        limit: Int = 10
    ) throws -> [VectorSearchResult] {
        let results = try index.search(query: queryVector, limit: limit)
        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.search", data: [
                "limit": limit,
                "results": results.count
            ])
        }
        return results.map { faissId, score in
            let entryId = reverseMapping[faissId] ?? "\(faissId)"
            let meta = metadata.entry(for: entryId)
            let resolved: VectorStoreMetadata.Entry? = {
                guard let m = meta else { return nil }
                let resolvedText = metadata.resolvedText(for: m) ?? m.text
                return VectorStoreMetadata.Entry(
                    id: m.id,
                    text: resolvedText,
                    source: m.source,
                    timestamp: m.timestamp,
                    category: m.category,
                    embeddingModel: m.embeddingModel,
                    sourceReference: m.sourceReference
                )
            }()
            return VectorSearchResult(id: entryId, score: score, metadata: resolved)
        }
    }

    // MARK: - Remove

    public func removeEntry(id: String) throws {
        guard let faissId = idMapping[id] else {
            throw VectorStoreError.idMappingError("No FAISS ID mapping for '\(id)'")
        }
        try index.remove(ids: [faissId])
        metadata.remove(id: id)
        idMapping.removeValue(forKey: id)
        reverseMapping.removeValue(forKey: faissId)
    }

    public func removeAll() throws {
        try index.reset()
        metadata.removeAll()
        idMapping.removeAll()
        reverseMapping.removeAll()
        nextId = 1
        Task.detached(priority: .utility) {
            await RAGTraceLogger.shared.log(type: "store.remove_all", data: [:])
        }
    }

    // MARK: - Query

    public func searchByText(
        query: String,
        embeddingGenerator: @Sendable (String) async throws -> [Float],
        limit: Int = 10
    ) async throws -> [VectorSearchResult] {
        let vector = try await embeddingGenerator(query)
        return try search(queryVector: vector, limit: limit)
    }

    // MARK: - Stats

    public var entryCount: Int {
        metadata.count
    }

    public var indexCount: Int {
        index.count
    }

    // MARK: - Internal

    private func rebuildIDMappings() {
        var next: Int64 = 1
        for entry in metadata.all {
            let faissId = next
            next += 1
            idMapping[entry.id] = faissId
            reverseMapping[faissId] = entry.id
        }
        nextId = next
    }

    private var mappingFileURL: URL {
        config.storePath.appendingPathComponent("id-mapping.json")
    }

    /// Persists the entry-id → FAISS-id mapping so reloads stay exact even
    /// after removals leave gaps in the index labels.
    private func persistIDMappings() throws {
        let payload: [String: Any] = [
            "nextId": NSNumber(value: nextId),
            "mapping": idMapping.map { [$0.key, NSNumber(value: $0.value)] },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: mappingFileURL, options: .atomic)
    }

    private func restoreIDMappingsFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: mappingFileURL),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let next = (payload["nextId"] as? NSNumber)?.int64Value,
              let rawMapping = payload["mapping"] as? [[Any]] else {
            return false
        }
        var mapping: [String: Int64] = [:]
        var reverse: [Int64: String] = [:]
        for pair in rawMapping {
            guard pair.count == 2,
                  let entryId = pair[0] as? String,
                  let faissId = (pair[1] as? NSNumber)?.int64Value else {
                return false
            }
            mapping[entryId] = faissId
            reverse[faissId] = entryId
        }
        guard mapping.count == metadata.all.count else { return false }
        idMapping = mapping
        reverseMapping = reverse
        nextId = next
        return true
    }
}
