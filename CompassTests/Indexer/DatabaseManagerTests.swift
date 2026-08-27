//
//  DatabaseManagerTests.swift
//  CompassTests
//
//  Created by Cascade on 24/12/2025.
//

import XCTest
@testable import Compass
import SQLite3

final class DatabaseManagerTests: XCTestCase {
    var dbManager: DatabaseManager!
    var tempDBPath: String!

    private let insertResourceSQL = """
    INSERT INTO resources (id, path, language, last_modified, content_hash, quality_score)
    VALUES (?, ?, ?, ?, ?, ?);
    """

    private let samplePaths = [
        "src/main.swift",
        "src/utils/helpers.swift",
        "README.md",
        "docs/guide.md"
    ]

    private func insertResource(id: String, path: String, qualityScore: Double, aiEnriched: Bool) async throws {
        if aiEnriched {
            let sql = """
            INSERT INTO resources (id, path, language, last_modified, content_hash, quality_score, ai_enriched)
            VALUES (?, ?, ?, ?, ?, ?, 1);
            """
            try await dbManager.execute(
                sql: sql,
                parameters: [id, path, "swift", 0.0, "hash", qualityScore]
            )
            return
        }

        try await dbManager.execute(
            sql: insertResourceSQL,
            parameters: [id, path, "swift", 0.0, "hash", qualityScore]
        )
    }

    private func insertResource(path: String, qualityScore: Double = 7.5) async throws {
        try await insertResource(id: UUID().uuidString, path: path, qualityScore: qualityScore, aiEnriched: false)
    }

    private func insertResources(paths: [String]) async throws {
        for path in paths {
            try await insertResource(path: path)
        }
    }

    private func insertAIEnrichedResource(path: String, qualityScore: Double) async throws {
        try await insertResource(id: UUID().uuidString, path: path, qualityScore: qualityScore, aiEnriched: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        tempDBPath = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite").path
        dbManager = try DatabaseManager(path: tempDBPath)
    }

    override func tearDown() async throws {
        dbManager = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    func testListResourcePaths_noResults() async throws {
        let results = try await dbManager.listResourcePaths(matching: nil, limit: 10, offset: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testListResourcePaths_withInserts() async throws {
        // Insert some test resources
        try await insertResources(paths: samplePaths)

        let results = try await dbManager.listResourcePaths(matching: nil, limit: 10, offset: 0)
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.contains("src/main.swift"))
        XCTAssertTrue(results.contains("README.md"))
    }

    func testListResourcePaths_withFilter() async throws {
        try await insertResources(paths: samplePaths)

        let results = try await dbManager.listResourcePaths(matching: "swift", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.contains("swift") })
    }

    func testHasResourcePath() async throws {
        let path = "src/main.swift"

        try await insertResource(path: path)

        let hasPath = try await dbManager.hasResourcePath(path)
        let missingPath = try await dbManager.hasResourcePath("src/nonexistent.swift")
        XCTAssertTrue(hasPath)
        XCTAssertFalse(missingPath)
    }

    func testFindResourceMatches() async throws {
        try await insertResources(paths: samplePaths)

        let results = try await dbManager.findResourceMatches(query: "swift", limit: 10)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.path.contains("swift") })
        XCTAssertTrue(results.allSatisfy { $0.aiEnriched == false })
        XCTAssertEqual(results.first?.qualityScore, 7.5)
    }

    func testFindResourceMatches_withAIEnriched() async throws {
        let path = "src/ai_enriched.swift"

        try await insertAIEnrichedResource(path: path, qualityScore: 9.2)

        let results = try await dbManager.findResourceMatches(query: "ai_enriched", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.aiEnriched == true)
        XCTAssertEqual(results.first?.qualityScore, 9.2)
    }

    func testSchemaTablesExist() async throws {
        // Validate all expected tables were created by the schema initializer.
        // A missing CREATE TABLE or syntax error in the schema SQL causes
        // DatabaseManager.init to throw on startup, crashing the app.
        for table in ["resources", "symbols", "symbol_names", "symbol_details", "symbol_locations"] {
            let sql = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;"
            let count = try await dbManager.scalarInt(sql: sql, parameters: [table])
            XCTAssertEqual(count, 1, "Expected table '\(table)' to exist in schema")
        }
    }}
