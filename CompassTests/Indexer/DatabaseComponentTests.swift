import XCTest
@testable import Compass

final class DatabaseComponentTests: XCTestCase {

    private func makeTempDatabaseManager() async throws -> DatabaseManager {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_db_component_tests_\(UUID().uuidString)")
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

    func testListResourcePathsAndHasResourcePath() async throws {
        let dbManager = try await makeTempDatabaseManager()

        try await insertResource(dbManager, id: "r1", path: "/tmp/project/src/a.swift")
        try await insertResource(dbManager, id: "r2", path: "/tmp/project/src/b.tsx")

        let all = try await dbManager.listResourcePaths(matching: nil, limit: 10, offset: 0)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains("/tmp/project/src/a.swift"))
        XCTAssertTrue(all.contains("/tmp/project/src/b.tsx"))

        let filtered = try await dbManager.listResourcePaths(matching: "a.swift", limit: 10, offset: 0)
        XCTAssertEqual(filtered, ["/tmp/project/src/a.swift"])

        let hasPath = try await dbManager.hasResourcePath("/tmp/project/src/a.swift")
        let missingPath = try await dbManager.hasResourcePath("/tmp/project/src/missing.swift")
        XCTAssertTrue(hasPath)
        XCTAssertFalse(missingPath)
    }

    func testFindResourceMatchesReturnsAIAndScore() async throws {
        let dbManager = try await makeTempDatabaseManager()

        let insertResourceSQL =
            "INSERT INTO resources (id, path, language, last_modified, content_hash, " +
            "quality_score, quality_details, ai_enriched, summary) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
        try await dbManager.execute(
            sql: insertResourceSQL,
            parameters: ["r1", "/tmp/project/src/a.swift", "swift", 1.0, "hash", 0.75, NSNull(), 1, NSNull()]
        )

        let matches = try await dbManager.findResourceMatches(query: "a.swift", limit: 10)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.path, "/tmp/project/src/a.swift")
        XCTAssertEqual(matches.first?.aiEnriched, true)
        XCTAssertEqual(matches.first?.qualityScore, 0.75)
    }
}
