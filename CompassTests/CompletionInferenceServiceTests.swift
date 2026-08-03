import XCTest
@testable import Compass

@MainActor
final class CompletionInferenceServiceTests: XCTestCase {
    private var defaultsSuiteName: String?

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CompletionInferenceServiceTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testRemoteOnlyReturnsNilWhenOfflineModeIsEnabled() async throws {
        let provider = AIServiceInlineCompletionProvider(
            aiServiceProvider: { TestAIService(result: "completion") },
            offlineModeChecker: TestOfflineModeChecker(isOfflineModeEnabled: true)
        )

        let result = try await provider.complete(
            prompt: "return a value",
            triggerReason: .manual,
            routingMode: .remoteOnly
        )

        XCTAssertNil(result)
    }

    func testRemoteOnlyUsesProviderOutputWhenOnline() async throws {
        let provider = AIServiceInlineCompletionProvider(
            aiServiceProvider: { TestAIService(result: "completion") },
            offlineModeChecker: TestOfflineModeChecker(isOfflineModeEnabled: false)
        )

        let result = try await provider.complete(
            prompt: "return a value",
            triggerReason: .manual,
            routingMode: .remoteOnly
        )

        XCTAssertEqual(result?.text, "completion")
        XCTAssertEqual(result?.source, .remote)
    }

    func testProviderReturnsNilForHybridModes() async throws {
        let provider = AIServiceInlineCompletionProvider(
            aiServiceProvider: { TestAIService(result: "completion") },
            offlineModeChecker: TestOfflineModeChecker(isOfflineModeEnabled: false)
        )

        let localResult = try await provider.complete(
            prompt: "return a value", triggerReason: .manual, routingMode: .hybridPreferLocal
        )
        let remoteResult = try await provider.complete(
            prompt: "return a value", triggerReason: .manual, routingMode: .hybridPreferRemote
        )

        XCTAssertNil(localResult)
        XCTAssertNil(remoteResult)
    }

    func testCompleteLocallyBindsToFixedFimModel() async throws {
        let defaults = UserDefaults(suiteName: defaultsSuiteName!)!
        defaults.removePersistentDomain(forName: defaultsSuiteName!)
        let settingsStore = SettingsStore(userDefaults: defaults)
        let selectionStore = LocalModelSelectionStore(settingsStore: settingsStore)

        let provider = AIServiceInlineCompletionProvider(
            remoteServiceProvider: { nil },
            localServiceProvider: { nil },
            localModelSelectionStore: selectionStore
        )

        let result = try await provider.completeLocally(
            prefix: "func foo() {", suffix: "\n}", maxTokens: 40
        )

        // FIM is hardwired to the fixed model: when it is installed the call
        // resolves it directly (no user-selectable model), otherwise nil.
        let isInstalled = LocalModelFileStore.isModelInstalled(LocalModelCatalog.fimModel)
        if isInstalled {
            XCTAssertNotNil(result, "completeLocally should resolve the fixed FIM model when installed")
        } else {
            XCTAssertNil(result, "completeLocally should return nil when the fixed FIM model is not installed")
        }
    }

    func testLocalOnlyRoutingUsesCompleteLocally() async throws {
        let recorder = PromptRecorder()
        let inferService = CompletionInferenceService(provider: recorder)

        let request = InlineCompletionRequest(
            requestId: UUID(),
            filePath: "/test.swift",
            language: "swift",
            prefix: "func foo() {",
            suffix: "\n}",
            cursorPosition: 13,
            scopeSummary: nil,
            symbols: [],
            retrievalContext: [],
            triggerReason: .manual,
            maxSuggestionLength: 40,
            maxTokens: 14,
            allowMultiline: true
        )

        let settings = InlineCompletionSettings(
            isEnabled: true,
            debounceMilliseconds: 0,
            aggressiveness: 0.3,
            maxSuggestionLength: 40,
            multilineEnabled: false,
            retrievalEnabled: false,
            routingMode: .localOnly,
            debugOverlayEnabled: false
        )

        let result = try await inferService.infer(for: request, settings: settings)

        XCTAssertNil(result, "localOnly should return nil because PromptRecorder.completeLocally returns nil")
        XCTAssertEqual(recorder.capturedLocallyPrefix, "func foo() {")
        XCTAssertEqual(recorder.capturedLocallySuffix, "\n}")
    }
}

@MainActor
private final class PromptRecorder: InlineCompletionProviding {
    var capturedPrompt: String?
    var capturedLocallyPrefix: String?
    var capturedLocallySuffix: String?

    func complete(prompt: String, triggerReason: CompletionTriggerReason, routingMode: InlineCompletionRoutingMode) async throws -> (text: String, source: InlineCompletionSource)? {
        capturedPrompt = prompt
        return ("result", .remote)
    }

    func completeLocally(prefix: String, suffix: String, maxTokens: Int) async throws -> (text: String, source: InlineCompletionSource)? {
        capturedLocallyPrefix = prefix
        capturedLocallySuffix = suffix
        return nil
    }

    func completeLocallyStreaming(prefix: String, suffix: String, maxTokens: Int) async throws -> AsyncThrowingStream<String, Error>? {
        capturedLocallyPrefix = prefix
        capturedLocallySuffix = suffix
        return nil
    }
}

@MainActor
private final class TestOfflineModeChecker: OfflineModeChecking {
    private let offlineModeEnabled: Bool

    init(isOfflineModeEnabled: Bool) {
        self.offlineModeEnabled = isOfflineModeEnabled
    }

    func isOfflineModeEnabled() async -> Bool {
        offlineModeEnabled
    }
}

private actor TestAIService: AIService {
    nonisolated let preservesCache: Bool = false
    private let result: String

    init(result: String = "completion") {
        self.result = result
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        AIServiceResponse(content: result, toolCalls: nil)
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        AIServiceResponse(content: result, toolCalls: nil)
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        AIServiceResponse(content: result, toolCalls: nil)
    }

    func explainCode(_ code: String) async throws -> String {
        fatalError("unused")
    }

    func refactorCode(_ code: String, instructions: String) async throws -> String {
        fatalError("unused")
    }

    func generateCode(_ prompt: String) async throws -> String {
        result
    }

    func fixCode(_ code: String, error: String) async throws -> String {
        fatalError("unused")
    }
}
