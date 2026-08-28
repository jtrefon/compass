import XCTest
@testable import Compass

@MainActor
final class CompletionInferenceServiceTests: XCTestCase {
    func testStreamingBindsToFixedFimModel() async throws {
        let provider = AIServiceInlineCompletionProvider()
        let model = LocalModelCatalog.fimModel
        let isInstalled = LocalModelFileStore.isModelInstalled(model)

        // Creating the stream must not load the model (weights load lazily on
        // first generation), so this is fast even when installed.
        let stream = try await provider.completeLocallyStreaming(
            prefix: "func foo() {", suffix: "\n}", maxTokens: 40
        )

        if isInstalled {
            XCTAssertNotNil(stream, "stream should resolve the fixed FIM model when installed")
        } else {
            XCTAssertNil(stream, "stream should return nil when the FIM model is not installed")
        }
    }

    func testInferStreamingPassesRequestThroughToProvider() async throws {
        let recorder = PromptRecorder()
        let inferService = CompletionInferenceService(provider: recorder)

        let request = InlineCompletionRequest(
            requestId: UUID(),
            language: "swift",
            prefix: "func foo() {",
            suffix: "\n}",
            triggerReason: .manual,
            maxSuggestionLength: 40,
            maxTokens: 14,
            bannedTokenIDs: [],
            variantTemperature: nil
        )
        let settings = InlineCompletionSettings(
            isEnabled: true,
            aggressiveness: 0.3,
            maxSuggestionLength: 40,
            debugOverlayEnabled: false
        )

        let stream = try await inferService.inferStreaming(for: request, settings: settings)

        XCTAssertNil(stream, "recorder returns nil (no model)")
        XCTAssertEqual(recorder.capturedLocallyPrefix, "func foo() {")
        XCTAssertEqual(recorder.capturedLocallySuffix, "\n}")
        XCTAssertEqual(recorder.capturedMaxTokens, 14)
    }
}
