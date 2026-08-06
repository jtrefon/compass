import XCTest
@testable import Compass

/// Shared completion test doubles (engine/bridge/policy tests).

@MainActor
final class TestLineInferenceService: CompletionInferring {
    enum Response {
        case immediate(String)
        case delayed(String, UInt64)
    }

    var responses: [Response] = []
    var capturedRequests: [InlineCompletionRequest] = []
    var firstTokenID: Int?

    var lastRequestMaxTokens: Int? { capturedRequests.last?.maxTokens }

    func lastGeneratedFirstTokenID() async -> Int? {
        firstTokenID
    }

    func inferStreaming(for request: InlineCompletionRequest, settings: InlineCompletionSettings) async throws -> AsyncThrowingStream<String, Error>? {
        capturedRequests.append(request)
        return AsyncThrowingStream<String, Error> { continuation in
            guard !self.responses.isEmpty else {
                continuation.finish()
                return
            }
            let response = self.responses.removeFirst()
            switch response {
            case .immediate(let text):
                continuation.yield(text)
                continuation.finish()
            case .delayed(let text, let delay):
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(text)
                    continuation.finish()
                }
            }
        }
    }
}

@MainActor
final class CapturedLineSuggestions: @unchecked Sendable {
    private(set) var lastSuggestion: String?
    private(set) var lastPresentation: InlineSuggestionPresentation?

    func set(_ presentation: InlineSuggestionPresentation?) {
        lastPresentation = presentation
        lastSuggestion = presentation?.suggestionText
    }

    func reset() {
        lastSuggestion = nil
        lastPresentation = nil
    }
}

@MainActor
final class LineTestSettingsStore: InlineCompletionSettingsStore {
    override func load() -> InlineCompletionSettings {
        InlineCompletionSettings(
            isEnabled: true, debounceMilliseconds: 0, aggressiveness: 0.6,
            maxSuggestionLength: 200, debugOverlayEnabled: false
        )
    }
}
