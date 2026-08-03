import XCTest
@testable import Compass

/// Pure orchestration harness — no mocks, no settings overrides, no env gates.
/// Uses the app's DependencyContainer EXACTLY as the real app does:
/// auto-detected launch context + user's saved provider configuration.
///
/// Principle: the harness orchestrates production code and collects telemetry.
/// It never reimplements, mocks, or patches. If this test fails, the APP
/// code needs fixing — not the harness.
@MainActor
final class PureAgenticHarnessTests: XCTestCase {

    // MARK: - Runtime setup (pure — no overrides)

    private func makeRuntime() async throws -> HarnessRuntime.Runtime {
        let runtime = try await HarnessRuntime.makeRuntime()
        // Set coder mode — the harness exercises agentic coding scenarios.
        // Chat mode is read-only and would block write/edit/bash tools.
        runtime.manager.currentMode = .coder
        return runtime
    }

    // MARK: - Send + wait (pure orchestration)

    private func sendAndWait(
        _ text: String,
        manager: ConversationManager,
        timeout: TimeInterval = 120
    ) async throws {
        _ = try await HarnessRuntime.sendAndWait(text, manager: manager, timeout: timeout)
    }

    // MARK: - Telemetry (read-only — no implementation)

    private func logTelemetry(_ manager: ConversationManager, label: String) {
        print("\n[HARNESS] === \(label) ===")
        print("[HARNESS]   messages: \(manager.messages.count)")
        let toolMsgs = manager.messages.filter { $0.isToolExecution }
        print("[HARNESS]   tool executions: \(toolMsgs.count)")
        let toolNames = Dictionary(grouping: toolMsgs, by: { $0.toolName ?? "?" })
            .mapValues { $0.count }
        for (name, count) in toolNames.sorted(by: { $0.value > $1.value }) {
            print("[HARNESS]     \(name): \(count)")
        }
        let assistantMsgs = manager.messages.filter { $0.role == .assistant && !$0.isDraft }
        for msg in assistantMsgs.suffix(3) {
            let preview = String(msg.content.prefix(300))
            print("[HARNESS]   assistant: \"\(preview)\"")
        }
        // Token usage (if billing metadata present)
        let billed = manager.messages.compactMap { $0.billing?.requestCostMicrodollars }.reduce(0, +)
        if billed > 0 {
            print("[HARNESS]   estimated cost: \(billed) microdollars")
        }
        print("[HARNESS] === end \(label) ===\n")
    }

    private func listAllFiles(under root: URL) -> [String] {
        HarnessRuntime.listAllFiles(under: root)
    }

    private func assertNoRawToolMarkup(_ manager: ConversationManager) {
        HarnessRuntime.assertNoRawToolMarkup(manager)
    }

    // MARK: - Tests

    func testHarnessFastPathGreeting() async throws {
        let runtime = try await makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.projectRoot) }

        try await sendAndWait("hi", manager: runtime.manager, timeout: 30)
        logTelemetry(runtime.manager, label: "fast-path-greeting")

        let assistantMsgs = runtime.manager.messages.filter { $0.role == .assistant && !$0.isDraft }
        XCTAssertFalse(assistantMsgs.isEmpty, "Expected at least one assistant response")
        XCTAssertTrue(assistantMsgs.last!.content.count > 5, "Response too short: \(assistantMsgs.last!.content)")
    }

    func testHarnessReactTodoAppEndToEnd() async throws {
        let runtime = try await makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.projectRoot) }

        // Phase 1: Create a React todo app via Vite
        print("\n[HARNESS] === Phase 1: Create React Todo App ===")
        try await sendAndWait(
            """
            Create a simple React Todo application using Vite.
            1. Create package.json with react and react-dom dependencies, and vite/dev scripts
            2. Create index.html with a root div
            3. Create src/main.jsx that imports and renders App
            4. Create src/App.jsx with a functional todo list component with add, toggle, and delete
            Write ALL files. When done, verify with `ls` then stop.
            """,
            manager: runtime.manager, timeout: 180
        )
        logTelemetry(runtime.manager, label: "phase1-created-todo")

        let files1 = listAllFiles(under: runtime.projectRoot)
        print("[HARNESS] Phase 1 files: \(files1)")
        XCTAssertTrue(files1.contains("package.json"), "Expected package.json")
        XCTAssertTrue(files1.contains("index.html"), "Expected index.html")
        XCTAssertTrue(files1.contains("src/main.jsx") || files1.contains("src/main.js"), "Expected entry file")
        let appFile = files1.first { $0.contains("App.jsx") || $0.contains("App.js") } ?? ""
        XCTAssertFalse(appFile.isEmpty, "Expected App component file")

        // Phase 2: Refactor to SSR with Express server
        print("\n[HARNESS] === Phase 2: Refactor to SSR ===")
        try await sendAndWait(
            """
            Refactor this application to Server-Side Rendering using Express.
            1. Install express and react-dom/server (update package.json)
            2. Create server.js that uses React's renderToString to serve the app
            3. Update index.html or create a template for SSR rendering
            4. Make sure the server runs on port 3000
            Write ALL files. When done, verify with `ls` then stop.
            """,
            manager: runtime.manager, timeout: 180
        )
        logTelemetry(runtime.manager, label: "phase2-ssr-refactor")

        let files2 = listAllFiles(under: runtime.projectRoot)
        print("[HARNESS] Phase 2 files: \(files2)")
        XCTAssertTrue(files2.contains("server.js") || files2.contains("server.mjs"),
            "Expected SSR server entrypoint. Files: \(files2)")

        // Phase 3: Add unit tests
        print("\n[HARNESS] === Phase 3: Add Unit Tests ===")
        try await sendAndWait(
            """
            Add unit tests for the Todo app.
            1. Install a testing framework (vitest or jest) — update package.json with test script
            2. Create a test file that tests the App component:
               - renders todo items
               - adds a new todo
               - toggles completion
               - deletes a todo
            Write ALL files. When done, verify with `ls` then stop.
            """,
            manager: runtime.manager, timeout: 180
        )
        logTelemetry(runtime.manager, label: "phase3-unit-tests")

        let files3 = listAllFiles(under: runtime.projectRoot)
        print("[HARNESS] Phase 3 files: \(files3)")
        let hasTestFile = files3.contains { $0.contains("test") || $0.contains("spec") || $0.contains(".test.") }
        XCTAssertTrue(hasTestFile, "Expected test file. Files: \(files3)")

        // Final validation
        assertNoRawToolMarkup(runtime.manager)
        print("\n[HARNESS] === COMPLETE: \(runtime.manager.messages.count) messages, " +
              "\(runtime.manager.messages.filter { $0.isToolExecution }.count) tool executions ===")
    }
}