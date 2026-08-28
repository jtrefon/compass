//
//  WriteFileToolTests.swift
//  CompassTests
//

import XCTest
@testable import Compass

@MainActor
final class WriteFileToolTests: XCTestCase {

    var fileSystemService: FileSystemService!
    var eventBus: EventBus!
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        fileSystemService = FileSystemService()
        eventBus = EventBus()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writefile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        fileSystemService = nil
        eventBus = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Basic Writes

    func testWriteNewFileSucceeds() async throws {
        let fileURL = tempDir.appendingPathComponent("new.txt")
        let tool = makeTool()

        let result = try await tool.execute(arguments: ToolArguments([
            "path": fileURL.path,
            "content": "hello world"
        ]))

        XCTAssertTrue(result.contains("Successfully wrote"))
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(written, "hello world")
    }

    func testWriteRefusesOverwriteOfExistingFile() async throws {
        let fileURL = tempDir.appendingPathComponent("overwrite.txt")
        try "original content".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = makeTool()
        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": fileURL.path,
                "content": "new content"
            ]))
            XCTFail("Expected DestructiveWriteGuardError for overwrite")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("DestructiveWriteGuard") || message.contains("Refused"))
        }
    }

    // MARK: - No-Op Detection

    func testNoOpWhenContentAlreadyMatches() async throws {
        let fileURL = tempDir.appendingPathComponent("noop.txt")
        try "same content".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = makeTool()
        let result = try await tool.execute(arguments: ToolArguments([
            "path": fileURL.path,
            "content": "same content"
        ]))

        XCTAssertTrue(result.contains("No-op"))
    }

    // MARK: - Error Cases

    func testMissingPathThrowsError() async throws {
        let tool = makeTool()
        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "content": "some content"
            ]))
            XCTFail("Expected error for missing path")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("path") || message.contains("Missing"))
        }
    }

    func testMissingContentThrowsError() async throws {
        let tool = makeTool()
        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": tempDir.appendingPathComponent("nope.txt").path
            ]))
            XCTFail("Expected error for missing content")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("content") || message.contains("Missing"))
        }
    }

    func testEmptyPathThrowsError() async throws {
        let tool = makeTool()
        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": "",
                "content": "content"
            ]))
            XCTFail("Expected error for empty path")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("path") || message.contains("Missing"))
        }
    }

    // MARK: - Propose/Apply Staging

    func testProposeModeDoesNotWriteFile() async throws {
        let fileURL = tempDir.appendingPathComponent("proposed.txt")
        let tool = makeTool()
        let patchSetID = "test-patch-\(UUID().uuidString)"

        let result = try await tool.execute(arguments: ToolArguments([
            "path": fileURL.path,
            "content": "proposed content",
            "mode": "propose",
            "patch_set_id": patchSetID
        ]))

        XCTAssertTrue(result.contains("proposed") || result.contains("Proposed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "Propose mode should not write file to disk")
    }

    // MARK: - Helpers

    private func makeTool() -> WriteFileTool {
        WriteFileTool(
            fileSystemService: fileSystemService,
            pathValidator: PathValidator(projectRoot: tempDir),
            eventBus: eventBus
        )
    }
}
