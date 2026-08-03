//
//  DatabaseManager.swift
//  Compass
//
//  Created by Cascade on 23/12/2025.
//

import Foundation
import SQLite3

public enum DatabaseError: Error {
    case openFailed
    case prepareFailed
    case stepFailed
    case bindFailed
    case executionFailed(String)
}

public class DatabaseManager {
    var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.Compass.database", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueID = UUID()

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private lazy var schemaManager = DatabaseSchemaManager(database: self)
    private lazy var symbolManager = DatabaseSymbolManager(database: self)
    private lazy var queryExecutor = DatabaseQueryExecutor(database: self)
    public init(path: String) throws {
        self.dbPath = path
        queue.setSpecific(key: queueKey, value: queueID)
        try open()
        try createTables()
    }

    deinit {
        close()
    }

    public func shutdown() {
        queue.sync {
            close()
        }
    }

    private func open() throws {
        if sqlite3_open_v2(
            dbPath,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            throw DatabaseError.openFailed
        }

        // Performance + integrity pragmas.
        // WAL significantly improves concurrent read/write behavior for an interactive IDE.
        // foreign_keys ensures ON DELETE CASCADE works for symbols/resources.
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    private func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    private func createTables() throws {
        try schemaManager.createTables()
    }

    // MARK: - Memory Operations

    public func saveSymbols(_ symbols: [Symbol]) throws {
        try symbolManager.saveSymbols(symbols)
    }

    public func deleteSymbols(for resourceId: String) throws {
        try symbolManager.deleteSymbols(for: resourceId)
    }

    public func listResourcePaths(matching query: String?, limit: Int, offset: Int) throws -> [String] {
        try queryExecutor.listResourcePaths(matching: query, limit: limit, offset: offset)
    }

    public func searchSymbolsWithPaths(nameLike query: String, limit: Int = 50) throws -> [SymbolSearchResult] {
        try symbolManager.searchSymbolsWithPaths(nameLike: query, limit: limit)
    }

    public func hasResourcePath(_ absolutePath: String) throws -> Bool {
        try queryExecutor.hasResourcePath(absolutePath)
    }

    public func findResourceMatches(query: String, limit: Int) throws -> [IndexedFileMatch] {
        try queryExecutor.findResourceMatches(query: query, limit: limit)
    }

    public func pruneResourcesOutside(projectRoot: URL) throws -> Int {
        try queryExecutor.pruneResourcesOutside(projectRoot: projectRoot)
    }

    public func pruneResourcesNotInPaths(_ knownPaths: Set<String>) throws -> Int {
        try queryExecutor.pruneResourcesNotInPaths(knownPaths)
    }

    public func getResourceLastModified(resourceId: String) throws -> Double? {
        try queryExecutor.getResourceLastModified(resourceId: resourceId)
    }

    public func searchSymbols(nameLike query: String, limit: Int = 50) throws -> [Symbol] {
        try symbolManager.searchSymbols(nameLike: query, limit: limit)
    }

    public func getIndexStatsCounts() throws -> IndexStatsCounts {
        try queryExecutor.getIndexStatsCounts()
    }

    public func getIndexedResourceCountScoped(projectRoot: URL, allowedExtensions: Set<String>) throws -> Int {
        let rootPrefix = DatabaseScopedPathQueryBuilder.rootPrefix(projectRoot: projectRoot)
        let extPredicates = DatabaseScopedPathQueryBuilder.fileExtensionPredicates(allowedExtensions: allowedExtensions)

        let sql = "SELECT COUNT(*) FROM resources WHERE path LIKE ? AND (\(extPredicates));"

        var parameters: [Any] = [rootPrefix + "%"]
        parameters.append(contentsOf: DatabaseScopedPathQueryBuilder.fileExtensionParameters(allowedExtensions: allowedExtensions))

        return try scalarInt(sql: sql, parameters: parameters)
    }

    public func isResourceAIEnriched(resourceId: String) throws -> Bool {
        try queryExecutor.isResourceAIEnriched(resourceId: resourceId)
    }

    public func getAIEnrichedSummaries(projectRoot: URL, limit: Int = 20) throws -> [(path: String, summary: String)] {
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

    public func getSymbolKindCounts() throws -> [String: Int] {
        try symbolManager.getSymbolKindCounts()
    }

    internal func withPreparedStatement<T>(
        sql: String,
        parameters: [Any] = [],
        work: (OpaquePointer) throws -> T
    ) throws -> T {
        try syncOnQueue {
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
    }

    public func execute(sql: String, parameters: [Any]) throws {
        _ = try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            if sqlite3_step(statement) != SQLITE_DONE {
                throw DatabaseError.stepFailed
            }
        }
    }

    func bindParameter(statement: OpaquePointer, index: Int32, value: Any) throws {
        if let string = value as? String {
            sqlite3_bind_text(
                statement,
                index,
                (string as NSString).utf8String,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        } else if let int = value as? Int {
            sqlite3_bind_int(statement, index, Int32(int))
        } else if let double = value as? Double {
            sqlite3_bind_double(statement, index, double)
        } else if let int32 = value as? Int32 {
            sqlite3_bind_int(statement, index, int32)
        } else if let int64 = value as? Int64 {
            sqlite3_bind_int64(statement, index, int64)
        } else if let data = value as? Data {
            data.withUnsafeBytes { bytes in
                let boundPointer = bytes.bindMemory(to: UInt8.self).baseAddress
                sqlite3_bind_blob(
                    statement,
                    index,
                    boundPointer,
                    Int32(data.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        } else if value is NSNull {
            sqlite3_bind_null(statement, index)
        } else {
            // Fallback for other types
            let stringValue = "\(value)"
            sqlite3_bind_text(
                statement,
                index,
                (stringValue as NSString).utf8String,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    public func execute(sql: String) throws {
        try syncOnQueue {
            try executeUnsafe(sql: sql)
        }
    }

    public func transaction(_ block: () throws -> Void) throws {
        try syncOnQueue {
            try executeUnsafe(sql: "BEGIN TRANSACTION")
            do {
                try block()
                try executeUnsafe(sql: "COMMIT")
            } catch {
                try? executeUnsafe(sql: "ROLLBACK")
                throw error
            }
        }
    }

    internal func scalarInt(sql: String, parameters: [Any] = []) throws -> Int {
        try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.stepFailed
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    internal func scalarDouble(sql: String, parameters: [Any] = []) throws -> Double {
        try withPreparedStatement(sql: sql, parameters: parameters) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.stepFailed
            }
            return sqlite3_column_double(statement, 0)
        }
    }

    /// Execute work on the database queue asynchronously.
    /// Since DatabaseStore is an actor, it already provides isolation, so we use async to avoid blocking.
    internal func asyncOnQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Synchronous version for internal use when already on the queue.
    /// WARNING: This should only be called from within asyncOnQueue or when already on the queue.
    internal func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            return try work()
        }
        // For legacy compatibility - but prefer asyncOnQueue
        return try queue.sync {
            try work()
        }
    }

    func locateSymbolId(name: String) throws -> Int? {
        try syncOnQueue {
            let sql = "SELECT id FROM symbol_names WHERE name = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, Self.sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func inspectSymbol(id: Int) throws -> (kind: String, scope: String, signature: String, parentName: String)? {
        let sql = "SELECT kind, scope, signature, parent_name FROM symbol_details WHERE id = ?;"
        return try syncOnQueue {
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
    }

    func whereSymbol(id: Int) throws -> [(filePath: String, lineStart: Int, lineEnd: Int)] {
        let sql = "SELECT file_path, line_start, line_end FROM symbol_locations WHERE symbol_id = ?;"
        return try syncOnQueue {
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
    }

    func insertSymbols(_ symbols: [ExtractedSymbol]) throws {
        try transaction {
            for sym in symbols {
                // Insert or get name ID
                try execute(sql: "INSERT OR IGNORE INTO symbol_names(name) VALUES (?);", parameters: [sym.name])
                let nameId: Int
                do {
                    nameId = try scalarInt(sql: "SELECT id FROM symbol_names WHERE name = ?;", parameters: [sym.name])
                } catch {
                    continue
                }
                // Insert details
                try execute(sql: """
                    INSERT OR REPLACE INTO symbol_details(id, kind, scope, signature, parent_name)
                    VALUES (?, ?, ?, ?, ?);
                """, parameters: [nameId, sym.kind, sym.scope, sym.signature, sym.parentName])
                // Insert location
                try execute(sql: """
                    INSERT OR REPLACE INTO symbol_locations(symbol_id, file_path, line_start, line_end)
                    VALUES (?, ?, ?, ?);
                """, parameters: [nameId, sym.filePath, sym.lineStart, sym.lineEnd])
            }
        }
    }

    func deleteSymbolsByFile(filePath: String) throws {
        let ids = try syncOnQueue {
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
        }
        try execute(sql: "DELETE FROM symbol_locations WHERE file_path = ?;", parameters: [filePath])
        for id in ids {
            try execute(sql: "DELETE FROM symbol_details WHERE id = ?;", parameters: [id])
            try execute(sql: "DELETE FROM symbol_names WHERE id = ? AND NOT EXISTS (SELECT 1 FROM symbol_locations WHERE symbol_id = ?);", parameters: [id, id])
        }
    }

    private func executeUnsafe(sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.executionFailed(message)
        }
    }
}
