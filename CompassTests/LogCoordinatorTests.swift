import XCTest
import Foundation
@testable import Compass

final class LogCoordinatorWritesTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-coordinator-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testWriteContextLog() async throws {
        let event = ContextLogEvent(
            conversationId: "test-conv",
            source: "chat.user_message",
            content: "Hello from test",
            metadata: ["mode": "coder"]
        )
        await LogCoordinator.writeContextLog(event, projectRoot: tempDir)

        let fileURL = tempDir
            .appendingPathComponent(".ide")
            .appendingPathComponent("logs")
            .appendingPathComponent("conversations")
            .appendingPathComponent("test-conv")
            .appendingPathComponent("conversation.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("chat.user_message"))
        XCTAssertTrue(content.contains("Hello from test"))
    }

    func testWriteToolResult() async throws {
        let event = ToolResultEvent(
            conversationId: "test-conv-2",
            toolCallId: "call-1",
            toolName: "web_search",
            type: "execute_success",
            input: "query",
            output: "results",
            duration: 1.5,
            metadata: ["resultLength": "100"]
        )
        await LogCoordinator.writeToolResult(event, projectRoot: tempDir)

        let convDir = tempDir
            .appendingPathComponent(".ide")
            .appendingPathComponent("logs")
            .appendingPathComponent("conversations")
            .appendingPathComponent("test-conv-2")

        let execFile = convDir.appendingPathComponent("executions.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: execFile.path))
        let execContent = try String(contentsOf: execFile, encoding: .utf8)
        XCTAssertTrue(execContent.contains("execute_success"))

        let convFile = convDir.appendingPathComponent("conversation.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: convFile.path))
        let convContent = try String(contentsOf: convFile, encoding: .utf8)
        XCTAssertTrue(convContent.contains("tool.execute_success"))
    }

    func testEventConformance() {
        let bus = EventBus()
        let ctx = ContextLogEvent(conversationId: "id", source: "x", content: "x")
        bus.publish(ctx)
        let tool = ToolResultEvent(conversationId: "id", toolCallId: "c", toolName: "t", type: "x")
        bus.publish(tool)
    }
}
