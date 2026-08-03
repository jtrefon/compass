import Foundation
import SQLite3

final class DatabaseSymbolManager {
    private unowned let database: DatabaseManager

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(database: DatabaseManager) {
        self.database = database
    }

    func saveSymbols(_ symbols: [Symbol]) throws {
        try database.transaction {
            let stmt = "INSERT INTO symbols (id, resource_id, name, kind, " +
                "line_start, line_end, description) VALUES (?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(database.db, stmt, -1, &statement, nil) != SQLITE_OK {
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

    func deleteSymbols(for resourceId: String) throws {
        let sql = "DELETE FROM symbols WHERE resource_id = ?;"
        try database.execute(sql: sql, parameters: [resourceId])
    }

    func searchSymbolsWithPaths(nameLike query: String, limit: Int = 50) throws -> [SymbolSearchResult] {
        let sql = Self.makeSearchSymbolsWithPathsSQL()

        return try database.syncOnQueue {
            let statement = try prepareStatement(sql)
            defer { sqlite3_finalize(statement) }

            bindSearchSymbolsWithPathsParameters(statement, query: query, limit: limit)

            var results: [SymbolSearchResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(makeSymbolSearchResult(from: statement))
            }
            return results
        }
    }

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

    private func bindSearchSymbolsWithPathsParameters(_ statement: OpaquePointer, query: String, limit: Int) {
        let pattern = "%\(query)%" as NSString
        sqlite3_bind_text(statement, 1, pattern.utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(limit))
    }

    func searchSymbols(nameLike query: String, limit: Int = 50) throws -> [Symbol] {
        let sql = "SELECT id, resource_id, name, kind, line_start, line_end, description " +
            "FROM symbols WHERE name LIKE ? ORDER BY name LIMIT ?;"

        let pattern = "%\(query)%" as NSString
        return try database.withPreparedStatement(sql: sql) { statement in
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
                results.append(
                    Symbol(
                        id: id,
                        resourceId: resourceId,
                        name: name,
                        kind: kind,
                        lineStart: lineStart,
                        lineEnd: lineEnd,
                        description: description
                    )
                )
            }
            return results
        }
    }

    func getSymbolKindCounts() throws -> [String: Int] {
        let sql = "SELECT kind, COUNT(*) FROM symbols GROUP BY kind;"
        return try database.withPreparedStatement(sql: sql) { statement in
            var results: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let kind = String(cString: sqlite3_column_text(statement, 0))
                let count = Int(sqlite3_column_int(statement, 1))
                results[kind] = count
            }
            return results
        }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database.db, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed
        }
        guard let statement else {
            throw DatabaseError.prepareFailed
        }
        return statement
    }

    private func makeSymbolSearchResult(from statement: OpaquePointer) -> SymbolSearchResult {
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
        let symbol = Symbol(
            id: id,
            resourceId: resourceId,
            name: name,
            kind: kind,
            lineStart: lineStart,
            lineEnd: lineEnd,
            description: description
        )
        return SymbolSearchResult(symbol: symbol, filePath: path)
    }
}
