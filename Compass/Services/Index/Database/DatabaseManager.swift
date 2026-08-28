import Foundation
import SQLite3

public enum DatabaseError: Error {
    case openFailed
    case prepareFailed
    case stepFailed
    case bindFailed
    case executionFailed(String)
}

// MARK: - Database value types

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

/// Owns the sqlite handle and serializes all access via actor isolation.
///
/// **Design rationale:**
/// - The raw `sqlite3` pointer is an unsafe resource that must never be touched
///   from outside its isolation domain. Making this an `actor` gives us
///   compiler-verified serialization — no `DispatchQueue`, no `NSLock`, no
///   `syncOnQueue` foot-guns.
/// - All methods are non-async actor methods: they run synchronously within the
///   actor (so `init` and internal calls need no `await`), but external callers
///   must `await` to hop onto the actor's executor.
/// - The former `DatabaseStore`, `DatabaseSchemaManager`, `DatabaseSymbolManager`,
///   and `DatabaseQueryExecutor` all touched the same handle, so they belonged in
///   the same isolation domain. Their logic lives here, organized by MARK.
public actor DatabaseManager {
    private var db: OpaquePointer?
    private let dbPath: String

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.dbPath = path
        try Self.openConnection(path: path, db: &db)
        try Self.executePragmas(db: db)
        try Self.createTables(db: db)
    }

    // MARK: - Connection lifecycle (static helpers callable from init)

    private static func openConnection(path: String, db: inout OpaquePointer?) throws {
        if sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
    }

    private static func executePragmas(db: OpaquePointer?) throws {
        try executeUnsafe(db: db, sql: "PRAGMA journal_mode = WAL;")
        try executeUnsafe(db: db, sql: "PRAGMA synchronous = NORMAL;")
        try executeUnsafe(db: db, sql: "PRAGMA foreign_keys = ON;")
    }

    private static func createTables(db: OpaquePointer?) throws {
        try createBaseSchema(db: db)
        try applyMigrations(db: db)
    }

    /// Closes the connection. After this the actor is unusable.
    public func shutdown() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Low-level SQL primitives

    func withPreparedStatement<T>(
        sql: String,
        parameters: [Any] = [],
        work: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed
        }
        guard let statement else {
            throw DatabaseError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            try bindParameter(statement: statement, index: Int32(index + 1), value: parameter)
        }

        return try work(statement)
    }

    public func execute(sql: String, parameters: [Any]) throws {
        _ = try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            if sqlite3_step(statement) != SQLITE_DONE {
                throw DatabaseError.stepFailed
            }
        }
    }

    public func execute(sql: String) throws {
        try Self.executeUnsafe(db: db, sql: sql)
    }

    public func transaction(_ block: () throws -> Void) throws {
        try Self.executeUnsafe(db: db, sql: "BEGIN TRANSACTION")
        do {
            try block()
            try Self.executeUnsafe(db: db, sql: "COMMIT")
        } catch {
            try? Self.executeUnsafe(db: db, sql: "ROLLBACK")
            throw error
        }
    }

    func scalarInt(sql: String, parameters: [Any] = []) throws -> Int {
        try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.stepFailed
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private static func executeUnsafe(db: OpaquePointer?, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.executionFailed(message)
        }
    }

    private func bindParameter(statement: OpaquePointer, index: Int32, value: Any) throws {
        switch value {
        case let string as String:
            sqlite3_bind_text(statement, index, (string as NSString).utf8String, -1, Self.sqliteTransient)
        case let int as Int:
            sqlite3_bind_int(statement, index, Int32(int))
        case let double as Double:
            sqlite3_bind_double(statement, index, double)
        case let int32 as Int32:
            sqlite3_bind_int(statement, index, int32)
        case let int64 as Int64:
            sqlite3_bind_int64(statement, index, int64)
        case let data as Data:
            data.withUnsafeBytes { bytes in
                let boundPointer = bytes.bindMemory(to: UInt8.self).baseAddress
                sqlite3_bind_blob(statement, index, boundPointer, Int32(data.count), Self.sqliteTransient)
            }
        case is NSNull:
            sqlite3_bind_null(statement, index)
        default:
            let stringValue = "\(value)"
            sqlite3_bind_text(statement, index, (stringValue as NSString).utf8String, -1, Self.sqliteTransient)
        }
    }

    // MARK: - Schema

    private static func createBaseSchema(db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS resources (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            language TEXT NOT NULL,
            last_modified REAL NOT NULL,
            content_hash TEXT,
            quality_score REAL,
            quality_details TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_resources_path ON resources(path);

        DROP TABLE IF EXISTS resources_fts;
        DROP TABLE IF EXISTS code_chunks;
        DROP TABLE IF EXISTS memory_embeddings;
        DROP TABLE IF EXISTS memories;

        CREATE TABLE IF NOT EXISTS symbols (
            id TEXT PRIMARY KEY,
            resource_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            line_end INTEGER NOT NULL,
            description TEXT,
            FOREIGN KEY(resource_id) REFERENCES resources(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
        CREATE INDEX IF NOT EXISTS idx_symbols_resource_id ON symbols(resource_id);

        CREATE TABLE IF NOT EXISTS symbol_names (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS symbol_details (
            id INTEGER PRIMARY KEY REFERENCES symbol_names(id),
            kind TEXT NOT NULL,
            scope TEXT DEFAULT '',
            signature TEXT DEFAULT '',
            parent_name TEXT DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_details_kind ON symbol_details(kind);
        CREATE INDEX IF NOT EXISTS idx_details_parent ON symbol_details(parent_name);

        CREATE TABLE IF NOT EXISTS symbol_locations (
            symbol_id INTEGER NOT NULL REFERENCES symbol_names(id),
            file_path TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            line_end INTEGER DEFAULT 0,
            PRIMARY KEY (symbol_id, file_path, line_start)
        );
        CREATE INDEX IF NOT EXISTS idx_locations_file ON symbol_locations(file_path);
        """
        try Self.executeUnsafe(db: db, sql: sql)
    }

    private static func applyMigrations(db: OpaquePointer?) throws {
        try Self.ensureColumnExists(db: db, table: "resources", column: "content_hash", columnDefinition: "TEXT")
        try Self.ensureColumnExists(db: db, table: "resources", column: "quality_score", columnDefinition: "REAL NOT NULL DEFAULT 0")
        try Self.ensureColumnExists(db: db, table: "resources", column: "quality_details", columnDefinition: "TEXT")
        try Self.ensureColumnExists(db: db, table: "resources", column: "ai_enriched", columnDefinition: "INTEGER NOT NULL DEFAULT 0")
        try Self.ensureColumnExists(db: db, table: "resources", column: "summary", columnDefinition: "TEXT")
    }

    private static func ensureColumnExists(db: OpaquePointer?, table: String, column: String, columnDefinition: String) throws {
        let sql = "PRAGMA table_info(\(table));"
        var existingColumns: Set<String> = []

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                existingColumns.insert(String(cString: namePtr))
            }
        }

        guard !existingColumns.contains(column) else { return }
        try executeUnsafe(db: db, sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(columnDefinition);")
    }

    // MARK: - Resource operations

    public func getResourceLastModified(resourceId: String) throws -> Double? {
        let sql = "SELECT last_modified FROM resources WHERE id = ? LIMIT 1;"
        return try withPreparedStatement(sql: sql) { statement -> Double? in
            sqlite3_bind_text(statement, 1, (resourceId as NSString).utf8String, -1, Self.sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_double(statement, 0)
        }
    }

    public func listResourcePaths(matching query: String?, limit: Int, offset: Int) throws -> [String] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        let parameters: [Any]
        if let queryText = trimmed, !queryText.isEmpty {
            sql = "SELECT path FROM resources WHERE LOWER(path) LIKE LOWER(?) ORDER BY path LIMIT ? OFFSET ?;"
            parameters = ["%\(queryText)%", limit, offset]
        } else {
            sql = "SELECT path FROM resources ORDER BY path LIMIT ? OFFSET ?;"
            parameters = [limit, offset]
        }

        return try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            var results: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(statement, 0) {
                    results.append(String(cString: ptr))
                }
            }
            return results
        }
    }

    public func hasResourcePath(_ absolutePath: String) throws -> Bool {
        let sql = "SELECT 1 FROM resources WHERE path = ? LIMIT 1;"
        return try withPreparedStatement(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (absolutePath as NSString).utf8String, -1, Self.sqliteTransient)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public func findResourceMatches(query: String, limit: Int) throws -> [IndexedFileMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let sql = "SELECT path, ai_enriched, quality_score FROM resources " +
            "WHERE LOWER(path) LIKE LOWER(?) ORDER BY path LIMIT ?;"
        let parameters: [Any] = ["%\(trimmed)%", limit]

        return try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            var results: [IndexedFileMatch] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathPtr = sqlite3_column_text(statement, 0) else { continue }
                let path = String(cString: pathPtr)
                let ai = sqlite3_column_int(statement, 1) != 0
                let isNull = sqlite3_column_type(statement, 2) == SQLITE_NULL
                let score: Double? = isNull ? nil : sqlite3_column_double(statement, 2)
                results.append(IndexedFileMatch(path: path, aiEnriched: ai, qualityScore: score))
            }
            return results
        }
    }

    public func isResourceAIEnriched(resourceId: String) throws -> Bool {
        let sql = "SELECT ai_enriched FROM resources WHERE id = ? LIMIT 1;"
        return try withPreparedStatement(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (resourceId as NSString).utf8String, -1, Self.sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    public func getIndexStatsCounts() throws -> IndexStatsCounts {
        let resourceCount = try scalarInt(sql: "SELECT COUNT(*) FROM resources;")
        let symbolCount = try scalarInt(sql: "SELECT COUNT(*) FROM symbol_names;")
        return IndexStatsCounts(indexedResourceCount: resourceCount, symbolCount: symbolCount)
    }

    public func getIndexedResourceCountScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Int {
        let rootPrefix = DatabaseScopedPathQueryBuilder.rootPrefix(projectRoot: projectRoot)
        let extPredicates = DatabaseScopedPathQueryBuilder.fileExtensionPredicates(allowedExtensions: allowedExtensions)
        let sql = "SELECT COUNT(*) FROM resources WHERE path LIKE ? AND (\(extPredicates));"
        var parameters: [Any] = [rootPrefix + "%"]
        parameters.append(contentsOf: DatabaseScopedPathQueryBuilder.fileExtensionParameters(allowedExtensions: allowedExtensions))
        return try scalarInt(sql: sql, parameters: parameters)
    }

    public func pruneResourcesOutside(projectRoot: URL) throws -> Int {
        let rootPath = projectRoot.standardizedFileURL.path
        let allowedPrefix = rootPath + "/%"
        let deleteSQL = "DELETE FROM resources WHERE path != ? AND path NOT LIKE ?;"
        try transaction {
            try execute(sql: deleteSQL, parameters: [rootPath, allowedPrefix])
        }
        return Int(sqlite3_changes(db))
    }

    public func pruneResourcesNotInPaths(_ knownPaths: Set<String>) throws -> Int {
        guard !knownPaths.isEmpty else { return 0 }
        let batchSize = 500
        var totalRemoved = 0

        let allPathsSql = "SELECT id, path FROM resources;"
        let resourcesToDelete = try withPreparedStatement(sql: allPathsSql) { statement -> [(String, String)] in
            var results: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idPtr = sqlite3_column_text(statement, 0),
                   let pathPtr = sqlite3_column_text(statement, 1) {
                    results.append((String(cString: idPtr), String(cString: pathPtr)))
                }
            }
            return results
        }

        let idsToDelete = resourcesToDelete.filter { !knownPaths.contains($0.1) }.map { $0.0 }
        guard !idsToDelete.isEmpty else { return 0 }

        for batchStart in stride(from: 0, to: idsToDelete.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, idsToDelete.count)
            let batch = Array(idsToDelete[batchStart..<batchEnd])
            let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
            let deleteSql = "DELETE FROM resources WHERE id IN (\(placeholders));"
            try transaction {
                try execute(sql: deleteSql, parameters: batch)
            }
            totalRemoved += Int(sqlite3_changes(db))
        }
        return totalRemoved
    }

    public func upsertResource(_ request: UpsertResourceRequest) throws {
        let sql = """
        INSERT INTO resources (id, path, language, last_modified)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            last_modified = excluded.last_modified,
            language = excluded.language;
        """
        try execute(sql: sql, parameters: [
            request.resourceId,
            request.path,
            request.language,
            request.timestamp
        ])
    }

    public func deleteResource(resourceId: String) throws {
        try execute(sql: "DELETE FROM resources WHERE id = ?;", parameters: [resourceId])
    }

    // MARK: - Symbol operations (legacy `symbols` table)

    public func saveSymbols(_ symbols: [Symbol]) throws {
        try transaction {
            let stmt = "INSERT INTO symbols (id, resource_id, name, kind, " +
                "line_start, line_end, description) VALUES (?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, stmt, -1, &statement, nil) != SQLITE_OK {
                throw DatabaseError.prepareFailed
            }
            defer { sqlite3_finalize(statement) }

            for symbol in symbols {
                sqlite3_bind_text(statement, 1, (symbol.id as NSString).utf8String, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 2, (symbol.resourceId as NSString).utf8String, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 3, (symbol.name as NSString).utf8String, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 4, (symbol.kind.rawValue as NSString).utf8String, -1, Self.sqliteTransient)
                sqlite3_bind_int(statement, 5, Int32(symbol.lineStart))
                sqlite3_bind_int(statement, 6, Int32(symbol.lineEnd))

                if let description = symbol.description {
                    sqlite3_bind_text(statement, 7, (description as NSString).utf8String, -1, Self.sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, 7)
                }

                if sqlite3_step(statement) != SQLITE_DONE {
                    throw DatabaseError.stepFailed
                }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    public func deleteSymbols(for resourceId: String) throws {
        let sql = "DELETE FROM symbols WHERE resource_id = ?;"
        try execute(sql: sql, parameters: [resourceId])
    }

    public func searchSymbolsWithPaths(nameLike query: String, limit: Int = 50) throws -> [SymbolSearchResult] {
        let sql = Self.makeSearchSymbolsWithPathsSQL()
        return try withPreparedStatement(sql: sql) { statement in
            let pattern = "%\(query)%" as NSString
            sqlite3_bind_text(statement, 1, pattern.utf8String, -1, Self.sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [SymbolSearchResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Self.makeSymbolSearchResult(from: statement))
            }
            return results
        }
    }

    public func searchSymbols(nameLike query: String, limit: Int = 50) throws -> [Symbol] {
        let sql = "SELECT id, resource_id, name, kind, line_start, line_end, description " +
            "FROM symbols WHERE name LIKE ? ORDER BY name LIMIT ?;"
        let pattern = "%\(query)%" as NSString

        return try withPreparedStatement(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, pattern.utf8String, -1, Self.sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [Symbol] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let resourceId = String(cString: sqlite3_column_text(statement, 1))
                let name = String(cString: sqlite3_column_text(statement, 2))
                let kindRaw = String(cString: sqlite3_column_text(statement, 3))
                let lineStart = Int(sqlite3_column_int(statement, 4))
                let lineEnd = Int(sqlite3_column_int(statement, 5))
                let descriptionPtr = sqlite3_column_text(statement, 6)
                let description = descriptionPtr.flatMap { String(cString: $0) }
                let kind = SymbolKind(rawValue: kindRaw) ?? .unknown
                results.append(Symbol(id: id, resourceId: resourceId, name: name, kind: kind, lineStart: lineStart, lineEnd: lineEnd, description: description))
            }
            return results
        }
    }

    public func getSymbolKindCounts() throws -> [String: Int] {
        let sql = "SELECT kind, COUNT(*) FROM symbols GROUP BY kind;"
        return try withPreparedStatement(sql: sql) { statement in
            var results: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let kind = String(cString: sqlite3_column_text(statement, 0))
                let count = Int(sqlite3_column_int(statement, 1))
                results[kind] = count
            }
            return results
        }
    }

    // MARK: - Symbol operations (new 3-table schema)

    func locateSymbolId(name: String) throws -> Int? {
        let sql = "SELECT id FROM symbol_names WHERE name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    func inspectSymbol(id: Int) throws -> (kind: String, scope: String, signature: String, parentName: String)? {
        let sql = "SELECT kind, scope, signature, parent_name FROM symbol_details WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(id))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let kind = String(cString: sqlite3_column_text(statement, 0))
        let scope = sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : ""
        let sig = sqlite3_column_type(statement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 2)) : ""
        let parent = sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : ""
        return (kind, scope, sig, parent)
    }

    func whereSymbol(id: Int) throws -> [(filePath: String, lineStart: Int, lineEnd: Int)] {
        let sql = "SELECT file_path, line_start, line_end FROM symbol_locations WHERE symbol_id = ?;"
        var results: [(String, Int, Int)] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(id))
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let start = Int(sqlite3_column_int(statement, 1))
            let end = Int(sqlite3_column_int(statement, 2))
            results.append((path, start, end))
        }
        return results
    }

    func insertSymbols(_ symbols: [ExtractedSymbol]) throws {
        try transaction {
            for sym in symbols {
                try execute(sql: "INSERT OR IGNORE INTO symbol_names(name) VALUES (?);", parameters: [sym.name])
                let nameId: Int
                do {
                    nameId = try scalarInt(sql: "SELECT id FROM symbol_names WHERE name = ?;", parameters: [sym.name])
                } catch {
                    continue
                }
                try execute(sql: """
                    INSERT OR REPLACE INTO symbol_details(id, kind, scope, signature, parent_name)
                    VALUES (?, ?, ?, ?, ?);
                """, parameters: [nameId, sym.kind, sym.scope, sym.signature, sym.parentName])
                try execute(sql: """
                    INSERT OR REPLACE INTO symbol_locations(symbol_id, file_path, line_start, line_end)
                    VALUES (?, ?, ?, ?);
                """, parameters: [nameId, sym.filePath, sym.lineStart, sym.lineEnd])
            }
        }
    }

    func deleteSymbolsByFile(filePath: String) throws {
        let ids: [Int] = {
            var ids: [Int] = []
            let sql = "SELECT symbol_id FROM symbol_locations WHERE file_path = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ids }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (filePath as NSString).utf8String, -1, Self.sqliteTransient)
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int(statement, 0)))
            }
            return ids
        }()
        try execute(sql: "DELETE FROM symbol_locations WHERE file_path = ?;", parameters: [filePath])
        for id in ids {
            try execute(sql: "DELETE FROM symbol_details WHERE id = ?;", parameters: [id])
            try execute(sql: "DELETE FROM symbol_names WHERE id = ? AND NOT EXISTS (SELECT 1 FROM symbol_locations WHERE symbol_id = ?);", parameters: [id, id])
        }
    }

    // MARK: - AI enrichment stubs

    public func getAIEnrichedSummaries(projectRoot: URL, limit: Int) throws -> [(path: String, summary: String)] {
        return []
    }

    public func getAIEnrichedResourceCountScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Int {
        return 0
    }

    public func getAverageAIQualityScoreScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Double {
        return 0.0
    }

    public func getAverageQualityScore() throws -> Double {
        return 0.0
    }

    // MARK: - Helpers

    private static func makeSearchSymbolsWithPathsSQL() -> String {
        """
        SELECT
            s.id,
            s.resource_id,
            s.name,
            s.kind,
            s.line_start,
            s.line_end,
            s.description,
            r.path
        FROM symbols s
        LEFT JOIN resources r ON r.id = s.resource_id
        WHERE s.name LIKE ?
        ORDER BY s.name
        LIMIT ?;
        """
    }

    private static func makeSymbolSearchResult(from statement: OpaquePointer) -> SymbolSearchResult {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let resourceId = String(cString: sqlite3_column_text(statement, 1))
        let name = String(cString: sqlite3_column_text(statement, 2))
        let kindRaw = String(cString: sqlite3_column_text(statement, 3))
        let lineStart = Int(sqlite3_column_int(statement, 4))
        let lineEnd = Int(sqlite3_column_int(statement, 5))
        let descriptionPtr = sqlite3_column_text(statement, 6)
        let description = descriptionPtr.flatMap { String(cString: $0) }
        let pathPtr = sqlite3_column_text(statement, 7)
        let path = pathPtr.flatMap { String(cString: $0) }
        let kind = SymbolKind(rawValue: kindRaw) ?? .unknown
        let symbol = Symbol(id: id, resourceId: resourceId, name: name, kind: kind, lineStart: lineStart, lineEnd: lineEnd, description: description)
        return SymbolSearchResult(symbol: symbol, filePath: path)
    }
}
