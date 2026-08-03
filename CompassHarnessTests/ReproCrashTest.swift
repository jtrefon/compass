import XCTest
@testable import Compass

/// Exact reproduction of user's failing scenario: "hi" → "review one of my plugins"
@MainActor
final class ReproCrashTest: XCTestCase {

    private var container: DependencyContainer!
    private var manager: ConversationManager!

    override func setUp() async throws {
        // WordPress fixture (same layout as the reported crash scenario).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repro_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default
        try "<?php\n".write(to: root.appendingPathComponent("wp-config-sample.php"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("wp-includes"), withIntermediateDirectories: true)
        try "<?php\n".write(to: root.appendingPathComponent("wp-includes/functions.php"), atomically: true, encoding: .utf8)

        let pluginDir = root.appendingPathComponent("wp-content/plugins/wp-signup-form")
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try "<?php\n/** Plugin Name: WP Signup Form */\n".write(to: pluginDir.appendingPathComponent("wp-signup-form.php"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: pluginDir.appendingPathComponent("includes"), withIntermediateDirectories: true)
        try "<?php class WPSignup {}\n".write(to: pluginDir.appendingPathComponent("includes/class-signup.php"), atomically: true, encoding: .utf8)

        let runtime = try await HarnessRuntime.makeRuntime()
        runtime.manager.currentMode = .coder
        runtime.container.workspaceService.currentDirectory = root
        runtime.container.projectCoordinator.configureProject(root: root)
        container = runtime.container
        manager = runtime.manager
        try await Task.sleep(nanoseconds: 500_000_000)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testGreetThenReview() async throws {
        // Step 1: "hi" — fast path
        _ = try await HarnessRuntime.sendAndWait("hi", manager: manager, timeout: 30)
        print("[REPRO] step1 msgs=\(manager.messages.count) tools=\(manager.messages.filter { $0.isToolExecution }.count)")

        // Step 2: "review one of my plugins" — review path
        _ = try await HarnessRuntime.sendAndWait("review one of my plugins", manager: manager, timeout: 120)

        let toolMsgs = manager.messages.filter { $0.isToolExecution }
        let assistantMsgs = manager.messages.filter { $0.role == .assistant && !$0.isDraft }

        print("[REPRO] step2 msgs=\(manager.messages.count) tools=\(toolMsgs.count)")
        for m in assistantMsgs {
            let fullContent = m.content
            print("[REPRO]   assistant (full, \(fullContent.count) chars):")
            print("[REPRO]     \"\(fullContent)\"")
            // Check for raw tool call markup in the content
            XCTAssertFalse(fullContent.contains("<tool_call"), "Raw <tool_call> leaked into assistant content")
            XCTAssertFalse(m.content.contains("```tool"), "Raw ```tool leaked into assistant content")
        }
        for t in toolMsgs {
            print("[REPRO]   tool: \(t.toolName ?? "?")")
        }

        // Must not crash: final assistant message should be meaningful
        let last = assistantMsgs.last
        XCTAssertNotNil(last)
        XCTAssertGreaterThan(last!.content.count, 10, "Final response too short: \(last!.content)")
    }
}