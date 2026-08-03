import XCTest
@testable import Compass

final class DatabaseComponentTests: XCTestCase {

    private func makeTempDatabaseManager() throws -> DatabaseManager {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_db_component_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let dbPath = tempRoot.appendingPathComponent("test.sqlite").path
        return try DatabaseManager(path: dbPath)
    }

    func testDatabaseQueryExecutorListResourcePathsAndHasResourcePath() throws {
        let databaseManager = try makeTempDatabaseManager()

        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"

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
        try databaseManager.execute(
            sql: insertResourceSQL,
            parameters: [
                "r2",
                "/tmp/project/src/b.tsx",
                "tsx",
                1.0,
                "hash2",
                0.0,
                NSNull(),
                0,
                NSNull()
            ]
        )

        let executor = DatabaseQueryExecutor(database: databaseManager)

        let all = try executor.listResourcePaths(matching: nil, limit: 10, offset: 0)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains("/tmp/project/src/a.swift"))
        XCTAssertTrue(all.contains("/tmp/project/src/b.tsx"))

        let filtered = try executor.listResourcePaths(matching: "a.swift", limit: 10, offset: 0)
        XCTAssertEqual(filtered, ["/tmp/project/src/a.swift"])

        XCTAssertTrue(try executor.hasResourcePath("/tmp/project/src/a.swift"))
        XCTAssertFalse(try executor.hasResourcePath("/tmp/project/src/missing.swift"))
    }

    func testDatabaseQueryExecutorFindResourceMatchesReturnsAIAndScore() throws {
        let databaseManager = try makeTempDatabaseManager()

        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"

        try databaseManager.execute(
            sql: insertResourceSQL,
            parameters: [
                "r1",
                "/tmp/project/src/a.swift",
                "swift",
                1.0,
                "hash",
                0.75,
                NSNull(),
                1,
                NSNull()
            ]
        )

        let executor = DatabaseQueryExecutor(database: databaseManager)
        let matches = try executor.findResourceMatches(query: "a.swift", limit: 10)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.path, "/tmp/project/src/a.swift")
        XCTAssertEqual(matches.first?.aiEnriched, true)
        XCTAssertEqual(matches.first?.qualityScore, 0.75)
    }


}
