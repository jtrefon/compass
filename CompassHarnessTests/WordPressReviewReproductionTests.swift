import XCTest
@testable import Compass

@MainActor
final class WordPressReviewReproductionTests: XCTestCase {

    private func makeRuntime() async throws -> (DependencyContainer, ConversationManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp_repro_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default

        try "<?php\n".write(to: root.appendingPathComponent("wp-config-sample.php"), atomically: true, encoding: .utf8)
        let wpIncludes = root.appendingPathComponent("wp-includes")
        try fm.createDirectory(at: wpIncludes, withIntermediateDirectories: true)
        try "<?php\n".write(to: wpIncludes.appendingPathComponent("functions.php"), atomically: true, encoding: .utf8)

        let signupDir = root.appendingPathComponent("wp-content/plugins/wp-signup-form/includes")
        try fm.createDirectory(at: signupDir, withIntermediateDirectories: true)
        try """
        <?php
        /** Plugin Name: WP Signup Form  Version: 1.0.0 */
        add_action('init', 'wp_signup_init');
        function wp_signup_init() { add_shortcode('wp_signup_form', 'wp_signup_render'); }
        function wp_signup_render() { return '<form id="signup-form"><input name="email"/></form>'; }
        """.write(to: signupDir.deletingLastPathComponent().appendingPathComponent("wp-signup-form.php"), atomically: true, encoding: .utf8)
        try """
        <?php
        class WP_Signup_Form {
            private $stages = ['email', 'details', 'confirm'];
            public function process_stage($stage, $data) { return $this->stages[$stage] ?? null; }
        }
        """.write(to: signupDir.appendingPathComponent("class-signup-form.php"), atomically: true, encoding: .utf8)

        let careerDir = root.appendingPathComponent("wp-content/plugins/career-register")
        try fm.createDirectory(at: careerDir, withIntermediateDirectories: true)
        try "<?php\n/** Plugin Name: Career Register  Version: 0.9.0 */\n".write(to: careerDir.appendingPathComponent("career-register.php"), atomically: true, encoding: .utf8)

        let runtime = try await HarnessRuntime.makeRuntime()
        runtime.manager.currentMode = .coder
        // Repoint the shared runtime at the WordPress fixture root.
        runtime.container.workspaceService.currentDirectory = root
        runtime.container.projectCoordinator.configureProject(root: root)

        try await Task.sleep(nanoseconds: 500_000_000)
        return (runtime.container, runtime.manager, root)
    }

    private func sendAndWait(_ text: String, manager: ConversationManager, timeout: TimeInterval = 120) async throws {
        _ = try await HarnessRuntime.sendAndWait(text, manager: manager, timeout: timeout)
    }

    private func logTurn(_ manager: ConversationManager, label: String) {
        let toolMsgs = manager.messages.filter { $0.isToolExecution }
        let names = Dictionary(grouping: toolMsgs, by: { $0.toolName ?? "?" }).mapValues { $0.count }
        print("\n[HARNESS] --- \(label) --- msg=\(manager.messages.count) tools=\(toolMsgs.count)")
        for (n, c) in names.sorted(by: { $0.value > $1.value }) { print("[HARNESS]   \(n): \(c)") }
        for m in manager.messages.filter({ $0.role == .assistant && !$0.isDraft }).suffix(1) {
            print("[HARNESS]   assistant: \"\(m.content.prefix(200))\"")
        }
    }

    func testWordPressPluginReviewAndFix() async throws {
        let (_, manager, root) = try await makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        // Step 1: Greeting — fast path, 1 call, 0 tools
        try await sendAndWait("hi", manager: manager, timeout: 15)

        // Step 2: Explore — classifier routes to review path
        try await sendAndWait("check my plugins", manager: manager, timeout: 30)

        // Step 3: Review specific plugin — reads files, delivers review
        try await sendAndWait("review wp-signup-form plugin", manager: manager, timeout: 60)

        // Step 4: Deep critique — identifies issues from context already gathered
        try await sendAndWait("""
identify the top 3 issues with this plugin: SOLID violations, DRY violations,
KISS/YAGNI over-engineering, design pattern misuses, OOP/clean code issues,
and multi-layered architecture problems. For each, propose the best fix.
Prioritize by impact.
""", manager: manager, timeout: 60)

        // Step 5: Fix the #1 issue — edits files
        try await sendAndWait("fix the most critical issue you identified", manager: manager, timeout: 120)

        logTurn(manager, label: "step5-fix")

        let totalTools = manager.messages.filter { $0.isToolExecution }.count
        let totalCost = manager.messages.compactMap { $0.billing?.requestCostMicrodollars }.reduce(0, +)

        print("\n[HARNESS] TOTAL tool execs: \(totalTools), cost: \(totalCost) microdollars")
        XCTAssertLessThan(totalTools, 30, "Should use <30 tool calls total")

        let last = manager.messages.filter { $0.role == .assistant && !$0.isDraft }.last
        XCTAssertNotNil(last, "Expected final response")
        XCTAssertGreaterThan(last!.content.count, 10, "Final response too short")
        print("\n[HARNESS] ALL CHECKS PASSED. Ready for manual verification.")
    }
}