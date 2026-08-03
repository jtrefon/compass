import Foundation
import SQLite3

final class DatabaseQueryExecutor {
    private unowned let database: DatabaseManager

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(database: DatabaseManager) {
        self.database = database
    }

    func listResourcePaths(matching query: String?, limit: Int, offset: Int) throws -> [String] {
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

        return try database.withPreparedStatement(sql: sql, parameters: parameters) { statement in
            var results: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(statement, 0) {
                    results.append(String(cString: ptr))
                }
            }
            return results
        }
    }

    func hasResourcePath(_ absolutePath: String) throws -> Bool {
        let sql = "SELECT 1 FROM resources WHERE path = ? LIMIT 1;"
        return try database.withPreparedStatement(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (absolutePath as NSString).utf8String, -1, Self.sqliteTransient)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func findResourceMatches(query: String, limit: Int) throws -> [IndexedFileMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let sql = "SELECT path, ai_enriched, quality_score FROM resources " +
            "WHERE LOWER(path) LIKE LOWER(?) ORDER BY path LIMIT ?;"

        let parameters: [Any] = ["%\(trimmed)%", limit]
        return try database.withPreparedStatement(sql: sql, parameters: parameters) { statement in
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

    func getResourceLastModified(resourceId: String) throws -> Double? {
        let sql = "SELECT last_modified FROM resources WHERE id = ? LIMIT 1;"
        return try database.withPreparedStatement(sql: sql) { statement -> Double? in
            sqlite3_bind_text(statement, 1, (resourceId as NSString).utf8String, -1, Self.sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_double(statement, 0)
        }
    }

    func isResourceAIEnriched(resourceId: String) throws -> Bool {
        let sql = "SELECT ai_enriched FROM resources WHERE id = ? LIMIT 1;"
        return try database.withPreparedStatement(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (resourceId as NSString).utf8String, -1, Self.sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    func getIndexStatsCounts() throws -> IndexStatsCounts {
        let resourceCount = try database.scalarInt(sql: "SELECT COUNT(*) FROM resources;")
        let symbolCount = try database.scalarInt(sql: "SELECT COUNT(*) FROM symbol_names;")
        return IndexStatsCounts(
            indexedResourceCount: resourceCount,
            symbolCount: symbolCount
        )
    }

    func pruneResourcesOutside(projectRoot: URL) throws -> Int {
        let rootPath = projectRoot.standardizedFileURL.path
        let allowedPrefix = rootPath + "/%"
        let deleteSQL = "DELETE FROM resources WHERE path != ? AND path NOT LIKE ?;"

        return try database.syncOnQueue {
            try database.transaction {
                try database.execute(sql: deleteSQL, parameters: [rootPath, allowedPrefix])
            }

            return Int(sqlite3_changes(database.db))
        }
    }

    func pruneResourcesNotInPaths(_ knownPaths: Set<String>) throws -> Int {
        guard !knownPaths.isEmpty else { return 0 }

        let batchSize = 500
        var totalRemoved = 0

        let allPathsSql = "SELECT id, path FROM resources;"
        let resourcesToDelete = try database.withPreparedStatement(sql: allPathsSql) { statement -> [(String, String)] in
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

            try database.syncOnQueue {
                try database.transaction {
                    try database.execute(sql: deleteSql, parameters: batch)
                }
                totalRemoved += Int(sqlite3_changes(database.db))
            }
        }

        return totalRemoved
    }
}
