import XCTest
import Foundation
@testable import Compass

@MainActor
final class QuickOpenFileFinderTests: XCTestCase {

    func testFindFilesRanksExactNameFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "x".write(to: root.appendingPathComponent("Readme.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "x".write(to: root.appendingPathComponent("docs/README.md"), atomically: true, encoding: .utf8)

        let finder = QuickOpenFileFinder()
        let results = finder.findFiles(query: "README.md", root: root, limit: 10)

        XCTAssertEqual(results.first, "README.md")
    }

    func testFindFilesSkipsNodeModulesAndGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        try "x".write(to: root.appendingPathComponent("node_modules/needle.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".git/needle.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("needle.txt"), atomically: true, encoding: .utf8)

        let finder = QuickOpenFileFinder()
        let results = finder.findFiles(query: "needle", root: root, limit: 10)

        XCTAssertEqual(results, ["needle.txt"])
    }
}
