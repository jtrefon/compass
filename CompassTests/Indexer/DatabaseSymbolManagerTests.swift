import XCTest
@testable import Compass

final class DatabaseSymbolManagerTests: XCTestCase {

    private func makeTempDatabaseManager() throws -> DatabaseManager {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_db_symbol_manager_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let dbPath = tempRoot.appendingPathComponent("test.sqlite").path
        return try DatabaseManager(path: dbPath)
    }

    func testSearchSymbolsWithPathsReturnsPathAndSymbol() throws {
        let databaseManager = try makeTempDatabaseManager()

        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"

        let insertSymbolSQL =
            "INSERT INTO symbols (id, resource_id, name, kind, line_start, line_end, description) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?);"

        try databaseManager.execute(
            sql: insertResourceSQL,
            parameters: [
                "r1",
                "/tmp/project/src/main.swift",
                "swift",
                1.0,
                "hash",
                0.0,
                NSNull(),
                0,
                NSNull()
            ]
        )

        try databaseManager.execute(
            sql: insertSymbolSQL,
            parameters: [
                "s1",
                "r1",
                "MyClass",
                "class",
                1,
                10,
                NSNull()
            ]
        )

        let symbols = DatabaseSymbolManager(database: databaseManager)
        let results = try symbols.searchSymbolsWithPaths(nameLike: "My", limit: 50)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.filePath, "/tmp/project/src/main.swift")
        XCTAssertEqual(results.first?.symbol.name, "MyClass")
        XCTAssertEqual(results.first?.symbol.kind, .class)
    }

    func testSearchSymbolsWithPathsRespectsLimit() throws {
        let databaseManager = try makeTempDatabaseManager()

        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"

        let insertSymbolSQL =
            "INSERT INTO symbols (id, resource_id, name, kind, line_start, line_end, description) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?);"

        try databaseManager.execute(
            sql: insertResourceSQL,
            parameters: [
                "r1",
                "/tmp/project/src/a.swift",
                "swift",
                1.0,
                "hash",
                0.0,
                NSNull(),
                0,
                NSNull()
            ]
        )

        for symbolIndex in 0..<3 {
            try databaseManager.execute(
                sql: insertSymbolSQL,
                parameters: [
                    "s\(symbolIndex)",
                    "r1",
                    "Sym\(symbolIndex)",
                    "function",
                    1,
                    1,
                    NSNull()
                ]
            )
        }

        let symbols = DatabaseSymbolManager(database: databaseManager)
        let results = try symbols.searchSymbolsWithPaths(nameLike: "Sym", limit: 2)

        XCTAssertEqual(results.count, 2)
    }
}
