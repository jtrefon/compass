import XCTest
@testable import Compass

/// Two-turn local-chat reproduction: the user's manual test crashed on the
/// SECOND reply (MLX assertion in Qwen35GatedDeltaNet during reshape).
@MainActor
final class LocalChatTwoTurnReproTests: XCTestCase {

    private func makeRuntime() async throws -> HarnessRuntime.Runtime {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded — skipping two-turn repro")
        }
        let runtime = try await HarnessRuntime.makeRuntime()
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        runtime.manager.currentMode = .chat
        return runtime
    }

    /// Issue 1 RED: committed assistant messages must never carry raw
    /// <think> markup — the local model thinks reliably, so a plain request
    /// produces a think block, and the commit boundary must split it into
    /// the reasoning field. Fails today (raw think lands in content).
    func testCommittedMessagesNeverContainThinkMarkup() async throws {
        let runtime = try await makeRuntime()
        let ok = try await HarnessRuntime.sendAndWait(
            "Explain how a binary search tree works in one short paragraph.",
            manager: runtime.manager,
            timeout: 300
        )
        XCTAssertTrue(ok, "Local run must complete")
        let committed = runtime.manager.messages.filter { $0.role == .assistant && !$0.isDraft }
        print("[THINK-RED] committed assistant messages: \(committed.count)")
        XCTAssertFalse(committed.isEmpty, "Expected at least one committed assistant message")
        for message in committed {
            let content = message.content
            print("[THINK-RED] content=\(String(content.prefix(80))) reasoning=\(message.reasoning.map { String($0.prefix(40)) } ?? "nil")")
            XCTAssertFalse(
                content.contains("<think") || content.contains("</think>"),
                "Committed assistant message contains raw think markup"
            )
        }
    }

    func testTwoTurnLocalChatDoesNotCrash() async throws {
        let runtime = try await makeRuntime()

        let firstOk = try await HarnessRuntime.sendAndWait("hi", manager: runtime.manager, timeout: 300)
        print("[LOCAL-REPRO] first ok=\(firstOk) msgs=\(runtime.manager.messages.count)")
        XCTAssertTrue(firstOk, "First local turn must complete")

        let secondOk = try await HarnessRuntime.sendAndWait("what is 2 + 2?", manager: runtime.manager, timeout: 300)
        print("[LOCAL-REPRO] second ok=\(secondOk) msgs=\(runtime.manager.messages.count)")
        XCTAssertTrue(secondOk, "Second local turn must complete without crashing")
    }
}
