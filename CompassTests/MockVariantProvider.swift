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
