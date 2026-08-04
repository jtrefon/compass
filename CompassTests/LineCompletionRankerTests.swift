import XCTest
@testable import Compass

@MainActor
final class LineCompletionRankerTests: XCTestCase {
    private func makeRequest(
        prefix: String = "",
        suffix: String = "",
        maxLength: Int = 200,
        multiline: Bool = false
    ) -> InlineCompletionRequest {
        InlineCompletionRequest(
            requestId: UUID(),
            filePath: nil,
            language: "swift",
            prefix: prefix,
            suffix: suffix,
            cursorPosition: prefix.count,
            scopeSummary: nil,
            symbols: [],
            retrievalContext: [],
            triggerReason: multiline ? .manual : .automatic,
            maxSuggestionLength: maxLength,
            maxTokens: max(10, maxLength / 3),
            allowMultiline: multiline
        )
    }

    private func makeResult(
        requestId: UUID,
        text: String,
        confidence: Double = 0.8
    ) -> InlineCompletionResult {
        InlineCompletionResult(
            requestId: requestId,
            suggestionText: text,
            confidenceScore: confidence,
            source: .local,
            latencyMs: 10
        )
    }

    // MARK: - Single-line acceptance

    func test_singleLine_simpleCSSProperty_isAccepted() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: ".foo {\n    colo", suffix: "\n}")
        let result = makeResult(requestId: request.requestId, text: "color: #007aff;")

        let presentation = ranker.rank(result, for: request, aggressiveness: 0.5)
        XCTAssertNotNil(presentation)
        XCTAssertEqual(presentation?.suggestionText, "color: #007aff;")
    }

    func test_singleLine_multilineInput_isRejected() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: ".foo {\n    ", suffix: "\n}")
        let result = makeResult(requestId: request.requestId, text: "\n    display: flex;\n    gap: 8px;")

        XCTAssertNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    func test_singleLine_duplicateSuffix_isRejected() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: "let x = ", suffix: "42")
        let result = makeResult(requestId: request.requestId, text: "42")

        XCTAssertNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    func test_singleLine_exceedsMaxLength_isRejected() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: "let x = ", suffix: "\n", maxLength: 5)
        let result = makeResult(requestId: request.requestId, text: "hello world")

        XCTAssertNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    func test_singleLine_whitespaceTrimming() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: ".foo {\n    ", suffix: "\n}")
        let result = makeResult(requestId: request.requestId, text: "  color: red;  ")

        let presentation = ranker.rank(result, for: request, aggressiveness: 0.5)
        XCTAssertEqual(presentation?.suggestionText, "color: red;")
    }

    // MARK: - Self-repetition detection

    func test_selfRepetition_simplePattern_isRejected() {
        let ranker = LineCompletionRanker()
        let request = makeRequest()
        let result = makeResult(requestId: request.requestId, text: "let x = let x = let x =")
        XCTAssertNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    func test_selfRepetition_noRepetition_isAccepted() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: "let x = ", suffix: "\n")
        let result = makeResult(requestId: request.requestId, text: "42")
        XCTAssertNotNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    // MARK: - Already typed detection

    func test_matchesLineContent_alreadyTyped_isRejected() {
        let ranker = LineCompletionRanker()
        let request = makeRequest(prefix: "let result = 42\nlet x = resul", suffix: "\n")
        let result = makeResult(requestId: request.requestId, text: "resul")
        XCTAssertNil(ranker.rank(result, for: request, aggressiveness: 0.5))
    }

    // MARK: - Aggressiveness

    func test_aggressiveness_high_acceptsLowConfidence() {
        let ranker = LineCompletionRanker()
        let request = makeRequest()
        let result = makeResult(requestId: request.requestId, text: "color: red;", confidence: 0.1)

        let presentation = ranker.rank(result, for: request, aggressiveness: 0.9)
        XCTAssertNotNil(presentation)
        XCTAssertEqual(presentation?.confidenceScore, 0.9)
    }

    func test_aggressiveness_low_usesConfidence() {
        let ranker = LineCompletionRanker()
        let request = makeRequest()
        let result = makeResult(requestId: request.requestId, text: "color: red;", confidence: 0.7)

        let presentation = ranker.rank(result, for: request, aggressiveness: 0.3)
        XCTAssertNotNil(presentation)
        XCTAssertEqual(presentation?.confidenceScore, 0.7)
    }
}
