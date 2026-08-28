import XCTest
import Foundation
@testable import Compass

@MainActor
final class CrashReporterTests: XCTestCase {

    func testCrashReporterWritesProjectCrashLog() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass-crash-reporter-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        await CrashReporter.shared.setProjectRoot(tempRoot)

        let error = NSError(domain: "test.crash", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        await CrashReporter.shared.capture(
            error,
            context: CrashReportContext(operation: "CrashReporterTests.testCrashReporterWritesProjectCrashLog"),
            metadata: ["key": "value"],
            file: "CrashReporterTests.swift",
            function: #function,
            line: #line
        )

        let crashLogURL = tempRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("crash.ndjson")

        let data = try Data(contentsOf: crashLogURL)
        let content = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(content.contains("crash.ndjson"), "Expected log to contain JSON events, not paths")
        XCTAssertTrue(content.contains("CrashReporterTests.testCrashReporterWritesProjectCrashLog"), "Expected operation to be present")
        XCTAssertTrue(content.contains("boom"), "Expected error description to be present")
        XCTAssertTrue(content.contains("\"key\""), "Expected metadata keys to be present")
    }
}
