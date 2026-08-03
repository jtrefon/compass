import XCTest
import Foundation
@testable import Compass

@MainActor
final class IndexScopeTests: XCTestCase {

    func testIndexExcludesSkipNodeModules() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_index_excludes_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let nodeModulesFile = tempRoot
            .appendingPathComponent("node_modules")
            .appendingPathComponent("somepkg")
            .appendingPathComponent("index.js")
        try FileManager.default.createDirectory(at: nodeModulesFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try "console.log('x')\n".write(to: nodeModulesFile, atomically: true, encoding: .utf8)

        let srcFile = tempRoot
            .appendingPathComponent("src")
            .appendingPathComponent("main.ts")
        try FileManager.default.createDirectory(at: srcFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try "export const x = 1\n".write(to: srcFile, atomically: true, encoding: .utf8)

        let patterns = IndexExcludePatternManager.loadExcludePatterns(projectRoot: tempRoot, defaultPatterns: IndexConfiguration.default.excludePatterns)
        let excludeFile = tempRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("index_exclude")
        XCTAssertTrue(FileManager.default.fileExists(atPath: excludeFile.path), "Expected \(AppConstantsFileSystem.projectDirName)/index_exclude to be created")

        let files = IndexFileEnumerator.enumerateProjectFiles(rootURL: tempRoot, excludePatterns: patterns)

        XCTAssertTrue(
            files.contains(where: { $0.standardizedFileURL.path == srcFile.standardizedFileURL.path }),
            "Expected src file to be enumerated"
        )
        XCTAssertFalse(
            files.contains(where: { $0.path.contains("node_modules") }),
            "Expected node_modules tree to be excluded from enumeration"
        )
    }

    // MARK: - Index framework detection (audit §7)

    func testIndexFrameworkDetectionExcludesWordPressCoreOnFreshSeed() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_framework_wp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Simulate a WordPress project layout
        for dir in ["wp-admin", "wp-includes", "wp-content/plugins/career-register", "wp-content/themes/twentytwentyfive", "wp-content/themes/my-custom-theme"] {
            try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(dir), withIntermediateDirectories: true, attributes: nil)
        }
        try "<?php\n".write(to: tempRoot.appendingPathComponent("wp-config-sample.php"), atomically: true, encoding: .utf8)
        try "<?php\n".write(to: tempRoot.appendingPathComponent("wp-content/plugins/career-register/career-register.php"), atomically: true, encoding: .utf8)

        // Detection should return wp-admin, wp-includes, and the bundled twenty* theme only.
        let detected = IndexFrameworkDetection.detectAdditionalExcludePatterns(projectRoot: tempRoot)
        XCTAssertTrue(detected.contains("wp-admin"), "Expected wp-admin detected. Got: \(detected)")
        XCTAssertTrue(detected.contains("wp-includes"), "Expected wp-includes detected. Got: \(detected)")
        XCTAssertTrue(detected.contains("wp-content/themes/twentytwentyfive"), "Expected stock twenty* theme excluded. Got: \(detected)")
        XCTAssertFalse(detected.contains("wp-content/themes/my-custom-theme"), "User theme must NOT be excluded. Got: \(detected)")
        XCTAssertFalse(detected.contains("wp-content/plugins"), "User plugins dir must NOT be excluded wholesale. Got: \(detected)")

        // Seeding should write these patterns into the fresh `index_exclude` file.
        let merged = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: tempRoot,
            defaultPatterns: IndexConfiguration.default.excludePatterns
        )
        XCTAssertTrue(merged.contains("wp-admin"), "Expected wp-admin in seeded patterns. Got: \(merged)")
        XCTAssertTrue(merged.contains("wp-includes"), "Expected wp-includes in seeded patterns. Got: \(merged)")

        let excludeFile = tempRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName)
            .appendingPathComponent("index_exclude")
        let written = try String(contentsOf: excludeFile, encoding: .utf8)
        XCTAssertTrue(written.contains("wp-admin"), "Expected wp-admin in index_exclude file. Got:\n\(written)")
        XCTAssertTrue(written.contains("wp-includes"), "Expected wp-includes in index_exclude file. Got:\n\(written)")
    }

    func testIndexFrameworkDetectionNoOpForNonWordPressProject() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_framework_nop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // A generic Swift project — no WordPress signatures.
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true, attributes: nil)
        try "import Foundation\n".write(to: tempRoot.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)

        let detected = IndexFrameworkDetection.detectAdditionalExcludePatterns(projectRoot: tempRoot)
        XCTAssertTrue(detected.isEmpty, "Expected no framework detection for generic project. Got: \(detected)")

        let merged = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: tempRoot,
            defaultPatterns: IndexConfiguration.default.excludePatterns
        )
        XCTAssertFalse(merged.contains("wp-admin"))
        XCTAssertFalse(merged.contains("wp-includes"))
    }

    func testIndexEnumeratesTSX() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_index_tsx_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tsxFile = tempRoot
            .appendingPathComponent("src")
            .appendingPathComponent("RegistrationPage.tsx")
        try FileManager.default.createDirectory(at: tsxFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try "export default function RegistrationPage() { return null }\n".write(to: tsxFile, atomically: true, encoding: .utf8)

        let patterns = IndexExcludePatternManager.loadExcludePatterns(projectRoot: tempRoot, defaultPatterns: IndexConfiguration.default.excludePatterns)
        let files = IndexFileEnumerator.enumerateProjectFiles(rootURL: tempRoot, excludePatterns: patterns)

        XCTAssertTrue(
            files.contains(where: { $0.standardizedFileURL.path == tsxFile.standardizedFileURL.path }),
            "Expected .tsx file to be enumerated"
        )
    }

    func testIndexReadFileFallsBackToDiskWhenNotIndexed() async throws {
        struct LocalMockAIService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
            func sendMessage(
                _ request: AIServiceMessageWithProjectRootRequest
            ) async throws -> AIServiceResponse {
                _ = request
                return AIServiceResponse(content: nil, toolCalls: nil)
            }

            func sendMessage(
                _ request: AIServiceHistoryRequest
            ) async throws -> AIServiceResponse {
                _ = request
                return AIServiceResponse(content: nil, toolCalls: nil)
            }
            func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
                try await sendMessage(request)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_index_read_fallback_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("src").appendingPathComponent("NewFile.tsx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)

        let index = try CodebaseIndex(eventBus: EventBus(), projectRoot: tempRoot, aiService: LocalMockAIService())

        // File is on disk but not in DB yet; should still be readable.
        let output = try index.readIndexedFile(path: "src/NewFile.tsx", startLine: 1, endLine: 2)
        XCTAssertTrue(output.contains("1 | line1"), "Expected line-numbered output")
        XCTAssertTrue(output.contains("2 | line2"), "Expected line-numbered output")
    }

    // MARK: - Hybrid exclusion list (predefined + dynamic [custom] section)

    func testExclusionFileCustomSectionRoundTrip() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_excl_hybrid_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let defaults = IndexConfiguration.default.excludePatterns

        // Fresh seed writes both sections.
        let seeded = IndexExcludePatternManager.loadExcludePatterns(projectRoot: tempRoot, defaultPatterns: defaults)
        XCTAssertEqual(Set(seeded), Set(defaults), "Seed should equal built-in defaults")

        // Agent additions persist to [custom]; built-in defaults are skipped.
        // ("vendor" and "node_modules" are both built-in defaults.)
        let added = try IndexExcludePatternManager.appendCustomPatterns(
            projectRoot: tempRoot,
            patterns: ["vendor", "node_modules", "my-toolchain-out"]
        )
        XCTAssertEqual(added, ["my-toolchain-out"], "built-in defaults (vendor, node_modules) must be skipped")

        // Reload merges defaults + custom.
        let merged = IndexExcludePatternManager.loadExcludePatterns(projectRoot: tempRoot, defaultPatterns: defaults)
        XCTAssertTrue(merged.contains("vendor"), "vendor comes from the built-in defaults")
        XCTAssertTrue(merged.contains("my-toolchain-out"), "custom pattern persists")
        XCTAssertEqual(merged.filter { $0 == "node_modules" }.count, 1, "No duplicate defaults after merge")

        // Removal works and persists (custom-only — defaults are not removable).
        let removed = try IndexExcludePatternManager.removeCustomPatterns(projectRoot: tempRoot, patterns: ["my-toolchain-out", "vendor"])
        XCTAssertEqual(removed, ["my-toolchain-out"], "vendor is built-in and cannot be removed")
        let after = IndexExcludePatternManager.loadExcludePatterns(projectRoot: tempRoot, defaultPatterns: defaults)
        XCTAssertFalse(after.contains("my-toolchain-out"))
        XCTAssertTrue(after.contains("vendor"), "built-in default unaffected by custom removal")
    }
}
