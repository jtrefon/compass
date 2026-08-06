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
        let store = LocalModelSelectionStore()
        await store.setOfflineModeEnabled(true)
        runtime.manager.currentMode = .chat
        return runtime
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
