import XCTest
import Foundation
@testable import Compass

@MainActor
final class WorkspaceFallbackSearcherTests: XCTestCase {

    func testSearchSkipsNodeModulesAndGitAndIdeDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(AppConstantsFileSystem.projectDirName),
            withIntermediateDirectories: true
        )

        try "needle".write(
            to: root.appendingPathComponent("node_modules/a.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "needle".write(
            to: root.appendingPathComponent(".git/a.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "needle".write(
            to: root.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("a.swift"),
            atomically: true,
            encoding: .utf8
        )

        try "line1\nneedle here\n".write(
            to: root.appendingPathComponent("src.swift"),
            atomically: true,
            encoding: .utf8
        )

        let searcher = WorkspaceFallbackSearcher()
        let results = await searcher.search(pattern: "needle", projectRoot: root, limit: 50)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.relativePath, "src.swift")
    }

    func testSearchTrimsAndCapsSnippet() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let long = String(repeating: "x", count: 300)
        let content = "  needle \(long)  \n"
        try content.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let searcher = WorkspaceFallbackSearcher()
        let results = await searcher.search(pattern: "needle", projectRoot: root, limit: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].line, 1)
        XCTAssertTrue(results[0].snippet.hasPrefix("needle"))
        XCTAssertLessThanOrEqual(results[0].snippet.count, 241)
    }

    func testSearchRespectsAllowedExtensions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "needle".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("a.bin"), atomically: true, encoding: .utf8)

        let searcher = WorkspaceFallbackSearcher(allowedExtensions: ["swift"])
        let results = await searcher.search(pattern: "needle", projectRoot: root, limit: 10)

        XCTAssertEqual(results.map(\.relativePath), ["a.swift"])
    }
}
