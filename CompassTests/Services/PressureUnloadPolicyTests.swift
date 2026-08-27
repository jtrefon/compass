import XCTest
@preconcurrency import MLXLMCommon
@testable import Compass

/// Issue 2 RED/GREEN: tiered memory-pressure unload policy.
/// - .warning must release FIM only (chat container + its KV retained).
/// - .critical releases everything.
/// - Both run behind MLXInferenceLock — an unload can never fire under a
///   live generation.
final class PressureUnloadPolicyTests: XCTestCase {

    /// Records unload calls; stands in for the real chat generator.
    private final class MockGenerating: LocalModelGenerating, @unchecked Sendable {
        let lock = NSLock()
        var unloadCalls: [(reason: String, persistKVTo: URL?)] = []
        var activeGeneration = false

        func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat?, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String?, prefixCache: PrefixCacheContext?) async throws -> AIServiceResponse {
            AIServiceResponse(content: "mock", toolCalls: nil)
        }

        func preload(modelId: String, modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws {}

        func unloadAllModels(reason: String, persistKVTo: URL?) async {
            lock.withLock {
                unloadCalls.append((reason, persistKVTo))
            }
        }

        func hasActiveGeneration() async -> Bool { activeGeneration }

        func unloadCount() -> Int {
            lock.withLock { unloadCalls.count }
        }
    }

    private final class FakeObserver: MemoryPressureObserving {
        let callback: @Sendable (MemoryPressureLevel) -> Void
        init(callback: @escaping @Sendable (MemoryPressureLevel) -> Void) {
            self.callback = callback
        }
    }

    private final class FIMFlag: @unchecked Sendable {
        var value = false
    }

    private let fimFlag = FIMFlag()

    override func setUp() async throws {
        fimFlag.value = false
        await InferenceUnloadRegistry.shared.register(label: InferenceUnloadRegistry.fimLabel) { [fimFlag] in
            fimFlag.value = true
        }
    }

    override func tearDown() async throws {
        await InferenceUnloadRegistry.shared.removeAllHandlers()
    }

    private final class CallbackBox: @unchecked Sendable {
        var callback: (@Sendable (MemoryPressureLevel) -> Void)?
    }

    private func makeService(mock: MockGenerating) -> (service: LocalModelProcessAIService, fire: @Sendable (MemoryPressureLevel) -> Void) {
        let box = CallbackBox()
        let service = LocalModelProcessAIService(
            selectionStore: LocalModelSelectionStore(),
            fileStore: LocalModelProcessAIService.LocalModelFileStoreAdapter(),
            generator: mock,
            eventBus: NoOpEventBus(),
            settingsStore: OpenRouterSettingsStore(),
            memoryPressureObserverFactory: { callback in
                box.callback = callback
                return FakeObserver(callback: callback)
            },
            activityCoordinator: nil,
            launchContext: AppLaunchContext(isTesting: true)
        )
        return (service, box.callback!)
    }

    /// RED 1: a warning-level event must NOT unload the chat container —
    /// FIM only. Fails today (unconditional unload, no level plumbing).
    func testWarningKeepsChatContainer() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        fire(.warning)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mock.unloadCount(), 0, ".warning must keep the chat container loaded")
        XCTAssertTrue(fimFlag.value, ".warning must release the FIM container")
        _ = service
    }

    /// RED 2: a critical-level event releases everything.
    func testCriticalUnloadsAll() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        fire(.critical)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mock.unloadCount(), 1, ".critical must unload the chat container")
        XCTAssertTrue(fimFlag.value, ".critical must release the FIM container")
        _ = service
    }

    /// RED 3: the unload must wait for MLXInferenceLock — it must not fire
    /// while a generation holds the lock.
    func testUnloadWaitsForLock() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        try await MLXInferenceLock.shared.acquire()

        fire(.critical)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(mock.unloadCount(), 0, "unload must wait while the inference lock is held")
        XCTAssertFalse(fimFlag.value, "unload must wait while the inference lock is held")

        await MLXInferenceLock.shared.release()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(mock.unloadCount(), 1, "unload must complete once the lock is released")
        XCTAssertTrue(fimFlag.value)
        _ = service
    }
}
