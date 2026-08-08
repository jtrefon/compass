import XCTest
@testable import Compass

/// Verifies the LOCAL agentic loop still executes real tools end-to-end with
/// the slimmed system prompt (1.8K tokens): model emits a structured call ->
/// the tool runs -> the result lands in history/disk.
@MainActor
final class LocalToolExecutionTests: XCTestCase {

    private func makeRuntime() async throws -> HarnessRuntime.Runtime {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded")
        }
        let runtime = try await HarnessRuntime.makeRuntime()
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        runtime.manager.currentMode = .coder
        return runtime
    }

    func testLocalLoopExecutesReadTool() async throws {
        let runtime = try await makeRuntime()
        let ok = try await HarnessRuntime.sendAndWait(
            "List the files in the project root directory.",
            manager: runtime.manager,
            timeout: 300
        )
        print("[TOOL-EXEC] read-tool run ok=\(ok) msgs=\(runtime.manager.messages.count)")

        let toolMessages = runtime.manager.messages.filter { $0.isToolExecution }
        print("[TOOL-EXEC] executed tools: \(toolMessages.map { $0.toolName ?? "?" }.joined(separator: ", "))")
        XCTAssertTrue(ok, "Local run must complete")
        XCTAssertTrue(
            toolMessages.contains { ["ls", "glob", "read", "search"].contains($0.toolName) },
            "Expected a real tool execution (ls/glob/read/search), got none"
        )
    }

    func testLocalLoopExecutesWriteTool() async throws {
        let runtime = try await makeRuntime()
        let target = runtime.projectRoot.appendingPathComponent("local-exec-proof.txt")

        let ok = try await HarnessRuntime.sendAndWait(
            "Create a file named local-exec-proof.txt in the project root containing the exact text: tool-execution-verified.",
            manager: runtime.manager,
            timeout: 300
        )
        print("[TOOL-EXEC] write-tool run ok=\(ok) msgs=\(runtime.manager.messages.count)")

        let toolMessages = runtime.manager.messages.filter { $0.isToolExecution }
        print("[TOOL-EXEC] executed tools: \(toolMessages.map { $0.toolName ?? "?" }.joined(separator: ", "))")
        XCTAssertTrue(ok, "Local run must complete")
        XCTAssertTrue(
            toolMessages.contains { ["write", "write_file", "create_file", "bash"].contains($0.toolName) },
            "Expected a write-family tool execution, got none"
        )
        let content = try? String(contentsOf: target, encoding: .utf8)
        print("[TOOL-EXEC] file on disk: \(content.map { String($0.prefix(40)) } ?? "MISSING")")
        XCTAssertNotNil(content, "Expected the file to exist on disk")
        XCTAssertTrue(content?.contains("tool-execution-verified") == true,
                      "Expected the written content to contain the requested text")
    }
}
