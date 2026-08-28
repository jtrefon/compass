import XCTest
@testable import Compass

final class DatabaseSymbolManagerTests: XCTestCase {

    private func makeTempDatabaseManager() async throws -> DatabaseManager {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_db_symbol_manager_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let dbPath = tempRoot.appendingPathComponent("test.sqlite").path
        return try DatabaseManager(path: dbPath)
    }

    private func insertResource(_ dbManager: DatabaseManager, id: String, path: String) async throws {
        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
        try await dbManager.execute(
            sql: insertResourceSQL,
            parameters: [id, path, "swift", 1.0, "hash", 0.0, NSNull(), 0, NSNull()]
        )
    }

    func testSearchSymbolsWithPathsReturnsPathAndSymbol() async throws {
        let dbManager = try await makeTempDatabaseManager()

        try await insertResource(dbManager, id: "r1", path: "/tmp/project/src/main.swift")

        let insertSymbolSQL =
            "INSERT INTO symbols (id, resource_id, name, kind, line_start, line_end, description) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?);"
        try await dbManager.execute(
            sql: insertSymbolSQL,
            parameters: ["s1", "r1", "MyClass", "class", 1, 10, NSNull()]
        )

        let results = try await dbManager.searchSymbolsWithPaths(nameLike: "My", limit: 50)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.filePath, "/tmp/project/src/main.swift")
        XCTAssertEqual(results.first?.symbol.name, "MyClass")
        XCTAssertEqual(results.first?.symbol.kind, .class)
    }

    func testSearchSymbolsWithPathsRespectsLimit() async throws {
        let dbManager = try await makeTempDatabaseManager()

        try await insertResource(dbManager, id: "r1", path: "/tmp/project/src/a.swift")

        let insertSymbolSQL =
            "INSERT INTO symbols (id, resource_id, name, kind, line_start, line_end, description) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?);"

        for symbolIndex in 0..<3 {
            try await dbManager.execute(
                sql: insertSymbolSQL,
                parameters: ["s\(symbolIndex)", "r1", "Sym\(symbolIndex)", "function", 1, 1, NSNull()]
            )
        }

        let results = try await dbManager.searchSymbolsWithPaths(nameLike: "Sym", limit: 2)
        XCTAssertEqual(results.count, 2)
    }
}
