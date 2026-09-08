import XCTest
@preconcurrency import MLXLMCommon
@testable import Compass

/// Memory-pressure eviction policy:
/// - .warning releases FIM only (chat container + its KV retained).
/// - .critical NEVER unloads the chat container — chat inference state is
///   core and survives memory pressure (eviction is provider-change-only).
///   Only transient memory is released (MLX buffer cache).
/// - Both run behind MLXInferenceLock.
final class PressureUnloadPolicyTests: XCTestCase {

    /// Records unload calls; stands in for the real chat generator.
    private final class MockGenerating: LocalModelGenerating, @unchecked Sendable {
        let lock = NSLock()
        var unloadCalls: [String] = []
        var transientReleaseCount = 0
        var activeGeneration = false

        func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat?, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String?, prefixCache: PrefixCacheContext?) async throws -> AIServiceResponse {
            AIServiceResponse(content: "mock", toolCalls: nil)
        }

        func preload(modelId: String, modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws {}

        func unloadAllModels(reason: String) async {
            lock.withLock {
                unloadCalls.append(reason)
            }
        }

        func releaseTransientMemory() async {
            lock.withLock {
                transientReleaseCount += 1
            }
        }

        func releaseConversationKV() async {
            lock.withLock {
                unloadCalls.append("release_conversation_kv")
            }
        }

        func currentCompressorPages() async -> Int? { nil }

        func hasActiveGeneration() async -> Bool { activeGeneration }

        func unloadCount() -> Int {
            lock.withLock { unloadCalls.count }
        }

        func releaseCount() -> Int {
            lock.withLock { transientReleaseCount }
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

    /// A warning-level event must NOT unload the chat container — FIM only.
    func testWarningKeepsChatContainer() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        fire(.warning)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mock.unloadCount(), 0, ".warning must keep the chat container loaded")
        XCTAssertTrue(fimFlag.value, ".warning must release the FIM container")
        _ = service
    }

    /// A critical-level event must NOT unload the chat container (eviction
    /// policy: provider changes only). Transient memory is released instead.
    func testCriticalKeepsChatContainer() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        fire(.critical)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mock.unloadCount(), 0, ".critical must keep the chat container loaded")
        XCTAssertEqual(mock.releaseCount(), 1, ".critical must release transient memory")
        XCTAssertTrue(fimFlag.value, ".critical must release the FIM container")
        _ = service
    }

    /// The chat container must survive even while no generation is in flight
    /// and the lock is free — no eviction between session prompts.
    func testCriticalNeverEvictsChatBetweenPrompts() async throws {
        let mock = MockGenerating()
        let (service, fire) = makeService(mock: mock)

        try await MLXInferenceLock.shared.acquire()
        fire(.critical)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(mock.unloadCount(), 0, "chat must never be unloaded on pressure")
        await MLXInferenceLock.shared.release()

        fire(.critical)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(mock.unloadCount(), 0, "chat must never be unloaded on pressure, even with the lock free")
        XCTAssertTrue(fimFlag.value)
        _ = service
    }
}