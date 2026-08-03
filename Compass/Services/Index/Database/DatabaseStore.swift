import Foundation

public enum DatabaseValue: Sendable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case null

    var anyValue: Any {
        switch self {
        case .string(let stringValue): return stringValue
        case .int(let intValue): return intValue
        case .int64(let int64Value): return int64Value
        case .double(let doubleValue): return doubleValue
        case .null: return NSNull()
        }
    }
}

public struct IndexStatsCounts: Sendable {
    public let indexedResourceCount: Int
    public let symbolCount: Int

    public init(indexedResourceCount: Int, symbolCount: Int) {
        self.indexedResourceCount = indexedResourceCount
        self.symbolCount = symbolCount
    }
}

public struct UpsertResourceRequest: Sendable {
    public let resourceId: String
    public let path: String
    public let language: String
    public let timestamp: Double

    public init(resourceId: String, path: String, language: String, timestamp: Double) {
        self.resourceId = resourceId
        self.path = path
        self.language = language
        self.timestamp = timestamp
    }
}

/// Actor-based database store providing thread-safe access to the index database.
/// Since this is an actor, all methods are implicitly async and provide isolation.
public actor DatabaseStore {
    private let database: DatabaseManager

    public init(path: String) throws {
        self.database = try DatabaseManager(path: path)
    }
    
    /// Async factory method for non-blocking initialization
    public static func create(path: String) async throws -> DatabaseStore {
        try DatabaseStore(path: path)
    }

    public func shutdown() {
        database.shutdown()
    }

    // MARK: - Resource Operations

    public func getResourceLastModified(resourceId: String) throws -> Double? {
        try database.getResourceLastModified(resourceId: resourceId)
    }

    public func listResourcePaths(matching query: String?, limit: Int, offset: Int) throws -> [String] {
        try database.listResourcePaths(matching: query, limit: limit, offset: offset)
    }

    public func findResourceMatches(query: String, limit: Int) throws -> [IndexedFileMatch] {
        try database.findResourceMatches(query: query, limit: limit)
    }

    public func pruneResourcesOutside(projectRoot: URL) throws -> Int {
        try database.pruneResourcesOutside(projectRoot: projectRoot)
    }

    public func pruneResourcesNotInPaths(_ knownPaths: Set<String>) throws -> Int {
        try database.pruneResourcesNotInPaths(knownPaths)
    }

    // MARK: - Symbol Operations

    public func saveSymbols(_ symbols: [Symbol]) throws {
        try database.saveSymbols(symbols)
    }

    public func saveSymbolsBatched(_ symbols: [Symbol], batchSize: Int = 250) async throws {
        guard batchSize > 0 else {
            try database.saveSymbols(symbols)
            return
        }

        if symbols.isEmpty {
            return
        }

        var index = 0
        while index < symbols.count {
            let end = min(symbols.count, index + batchSize)
            try database.saveSymbols(Array(symbols[index..<end]))
            index = end

            if index < symbols.count {
                await Task.yield()
            }
        }
    }

    public func deleteSymbols(for resourceId: String) throws {
        try database.deleteSymbols(for: resourceId)
    }

    public func searchSymbols(nameLike query: String, limit: Int) throws -> [Symbol] {
        try database.searchSymbols(nameLike: query, limit: limit)
    }

    public func searchSymbolsWithPaths(nameLike query: String, limit: Int) throws -> [SymbolSearchResult] {
        try database.searchSymbolsWithPaths(nameLike: query, limit: limit)
    }

    // MARK: - AI Enrichment Operations (stubs — always return defaults)

    public func isResourceAIEnriched(resourceId: String) throws -> Bool {
        try database.isResourceAIEnriched(resourceId: resourceId)
    }

    public func getAIEnrichedSummaries(projectRoot: URL, limit: Int) throws -> [(path: String, summary: String)] {
        try database.getAIEnrichedSummaries(projectRoot: projectRoot, limit: limit)
    }

    public func getAIEnrichedResourceCountScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Int {
        try database.getAIEnrichedResourceCountScoped(projectRoot: projectRoot, allowedExtensions: allowedExtensions)
    }

    public func getAverageAIQualityScoreScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Double {
        try database.getAverageAIQualityScoreScoped(projectRoot: projectRoot, allowedExtensions: allowedExtensions)
    }

    public func getAverageQualityScore() throws -> Double {
        try database.getAverageQualityScore()
    }

    // MARK: - Stats Operations

    public func getIndexStatsCounts() throws -> IndexStatsCounts {
        try database.getIndexStatsCounts()
    }

    public func getIndexedResourceCountScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Int {
        try database.getIndexedResourceCountScoped(projectRoot: projectRoot, allowedExtensions: allowedExtensions)
    }

    public func getSymbolKindCounts() throws -> [String: Int] {
        try database.getSymbolKindCounts()
    }

    // MARK: - New Symbol Table Operations

    public func locateSymbolId(name: String) throws -> Int? {
        try database.locateSymbolId(name: name)
    }

    public func inspectSymbol(id: Int) throws -> (kind: String, scope: String, signature: String, parentName: String)? {
        try database.inspectSymbol(id: id)
    }

    public func whereSymbol(id: Int) throws -> [(filePath: String, lineStart: Int, lineEnd: Int)] {
        try database.whereSymbol(id: id)
    }

    public func insertSymbols(_ symbols: [ExtractedSymbol]) throws {
        try database.insertSymbols(symbols)
    }

    public func deleteSymbolsByFile(filePath: String) throws {
        try database.deleteSymbolsByFile(filePath: filePath)
    }

    // MARK: - Raw Operations

    public func execute(sql: String, parameters: [DatabaseValue]) throws {
        try database.execute(sql: sql, parameters: parameters.map { $0.anyValue })
    }

    public func upsertResource(_ request: UpsertResourceRequest) throws {
        let sql = """
        INSERT INTO resources (id, path, language, last_modified)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            last_modified = excluded.last_modified,
            language = excluded.language;
        """
        try database.execute(sql: sql, parameters: [
            request.resourceId,
            request.path,
            request.language,
            request.timestamp
        ])
    }

    public func deleteResource(resourceId: String) throws {
        try database.execute(sql: "DELETE FROM resources WHERE id = ?;", parameters: [resourceId])
    }
}
