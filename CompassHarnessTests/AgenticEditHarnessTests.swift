import XCTest
@testable import Compass

/// End-to-end confirmation that the agent can EDIT existing code: read the
/// file, apply a targeted edit (old_string/new_string), and have the change
/// land on disk. Guards the failed-tool-retry fix — an edit error must never
/// end the run with the file untouched.
@MainActor
final class AgenticEditHarnessTests: XCTestCase {

    private func makeEditProject() async throws -> HarnessRuntime.Runtime {
        let runtime = try await HarnessRuntime.makeRuntime()
        runtime.manager.currentMode = .coder

        // Seed a small existing source file the agent must edit.
        let fileURL = runtime.projectRoot.appendingPathComponent("sample.php")
        try """
        <?php
        class Sample {
            public function greet() {
                return "hello";
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        return runtime
    }

    func testAgentEditsExistingFile() async throws {
        let runtime = try await makeEditProject()
        defer { try? FileManager.default.removeItem(at: runtime.projectRoot) }
        let manager = runtime.manager

        let completed = try await HarnessRuntime.sendAndWait(
            "Edit sample.php: rename the class Sample to SampleV2 and change the greeting so it returns \"hi\". Read the file first, then edit it, then verify the result.",
            manager: manager,
            timeout: 240
        )
        XCTAssertTrue(completed, "Run must complete within the deadline")

        let fileURL = runtime.projectRoot.appendingPathComponent("sample.php")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        print("[HARNESS] file after edit:\n\(content)")
        XCTAssertTrue(content.contains("class SampleV2"), "Class rename must land on disk")
        XCTAssertTrue(content.contains("return \"hi\""), "Greeting change must land on disk")
        HarnessRuntime.assertNoRawToolMarkup(manager)
        logTelemetry(manager, runtime: runtime)
    }

    private func logTelemetry(_ manager: ConversationManager, runtime: HarnessRuntime.Runtime) {
        let store = runtime.container.settingsStore
        let model = store.string(forKey: "OpenRouterModel") ?? "(default)"
        let offline = store.bool(forKey: "AI.OfflineModeEnabled", default: false)
        let provider = offline ? "local-mlx" : "cloud"
        print("[HARNESS] mode=\(manager.currentMode.rawValue) provider=\(provider) model=\(model)")
        print("[HARNESS] projectRoot=\(runtime.projectRoot.path)")
        print("[HARNESS] selectedConversationId=\(manager.currentConversationId)")
        print("[HARNESS] defaultsSuite=\(AppRuntimeEnvironment.userDefaults != UserDefaults.standard ? "isolated" : "standard")")






        let toolMsgs = manager.messages.filter { $0.isToolExecution }
        let names = Dictionary(grouping: toolMsgs, by: { $0.toolName ?? "?" }).mapValues { $0.count }
        print("\n[HARNESS] messages=\(manager.messages.count) tools=\(toolMsgs.count)")
        for (n, c) in names.sorted(by: { $0.value > $1.value }) { print("[HARNESS]   \(n): \(c)") }
        for m in manager.messages.filter({ $0.role == .assistant && !$0.isDraft }).suffix(2) {
            print("[HARNESS]   assistant: \"\(m.content.prefix(300))\"")
        }
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: runtime.projectRoot.appendingPathComponent(".ide/orchestration/runs").path)) ?? []
        print("[HARNESS] orchestration run snapshots: \(runs)")
    }
}
