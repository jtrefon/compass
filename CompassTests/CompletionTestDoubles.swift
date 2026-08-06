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
            isEnabled: true, aggressiveness: 0.6,
            maxSuggestionLength: 200, debugOverlayEnabled: false
        )
    }
}

import XCTest
@testable import Compass

/// Canned-stream provider for chain tests.
@MainActor
final class MockVariantProvider: InlineCompletionProviding {
    var texts: [String] = []
    var firstTokens: [Int] = []
    var delayPerStreamMs: Int = 0
    private(set) var callsMade = 0
    private(set) var bansSeen: [[Int]] = []
    private(set) var firstTokensRequested = 0
    private var textIndex = 0
    private var tokenIndex = 0

    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int,
        bannedTokenIDs: [Int],
        variantTemperature: Float?
    ) async throws -> AsyncThrowingStream<String, Error>? {
        callsMade += 1
        bansSeen.append(bannedTokenIDs)
        guard textIndex < texts.count else { return nil }
        let text = texts[textIndex]
        textIndex += 1
        return AsyncThrowingStream { continuation in
            if self.delayPerStreamMs > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(self.delayPerStreamMs) * 1_000_000)
                    continuation.yield(text)
                    continuation.finish()
                }
            } else {
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    func lastGeneratedFirstTokenID() async -> Int? {
        firstTokensRequested += 1
        guard tokenIndex < firstTokens.count else { return nil }
        defer { tokenIndex += 1 }
        return firstTokens[tokenIndex]
    }
}

@MainActor
final class PromptRecorder: InlineCompletionProviding {
    var capturedLocallyPrefix: String?
    var capturedLocallySuffix: String?
    var capturedMaxTokens: Int?

    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int,
        bannedTokenIDs: [Int],
        variantTemperature: Float?
    ) async throws -> AsyncThrowingStream<String, Error>? {
        capturedLocallyPrefix = prefix
        capturedLocallySuffix = suffix
        capturedMaxTokens = maxTokens
        return nil
    }

    func lastGeneratedFirstTokenID() async -> Int? {
        nil
    }
}

