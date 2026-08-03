import XCTest
@testable import Compass

/// Tests the LineCompletionEngine request lifecycle, cancellation, and acceptance.
@MainActor
final class LineCompletionEngineTests: XCTestCase {

    // MARK: - Single request lifecycle

    func test_engine_immediateRequest_returnsSuggestion() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("color: red;")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: ".foo {\n    colo", cursor: 14), gapMs: 200, typedChar: "o")

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "color: red;")
    }

    func test_engine_noResponse_publishesNil() async throws {
        let inference = TestLineInferenceService()
        inference.responses = []

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: "foo", cursor: 3), gapMs: 200, typedChar: "o")

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(captured.lastSuggestion)
    }

    // MARK: - Sequential requests

    func test_engine_threeSequentialRequests_allSucceed() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [
            .immediate("font-family: serif;"),
            .immediate("color: blue;"),
            .immediate("background: white;")
        ]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        // Request 1
        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-fam", cursor: 16), gapMs: 200, typedChar: "m")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "font-family: serif;", "First request should succeed")

        // Accept
        engine.markAccepted(on: .primary, suggestionText: captured.lastSuggestion)

        // Request 2
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-family: serif;\n    colo", cursor: 40), gapMs: 200, typedChar: "o")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "color: blue;", "Second request after accept should succeed")

        // Accept
        engine.markAccepted(on: .primary, suggestionText: captured.lastSuggestion)

        // Request 3
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-family: serif;\n    color: blue;\n    backg", cursor: 63), gapMs: 200, typedChar: "g")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "background: white;", "Third request after two accepts should succeed")
    }

    // MARK: - Out-of-order (later request completes first)

    func test_engine_lateRequestWins_overEarlySlowRequest() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [
            .delayed("old", 200_000_000),
            .immediate("new")
        ]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: "first", cursor: 5), gapMs: 200, typedChar: "t")
        engine.requestCompletion(for: snapshot(buffer: "second", cursor: 6), gapMs: 200, typedChar: "d")

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(captured.lastSuggestion, "new", "Later request result should win")
    }

    // MARK: - Contextual filter suppresses low-value requests

    func test_engine_contextualFilter_suppressesClosingParen() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("will not show")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: "foo)", cursor: 4), gapMs: 0, typedChar: ")")

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(captured.lastSuggestion, "Contextual filter should suppress on )")
    }

    // MARK: - Helpers

    private func makeEngine(
        inference: TestLineInferenceService
    ) -> LineCompletionEngine {
        LineCompletionEngine(
            inferenceService: inference,
            settingsStore: LineTestSettingsStore()
        )
    }

    private func snapshot(buffer: String, cursor: Int) -> InlineCompletionEditorSnapshot {
        InlineCompletionEditorSnapshot(
            paneID: .primary,
            filePath: "/tmp/test.css",
            language: "css",
            buffer: buffer,
            cursorPosition: cursor,
            selectionLength: 0,
            isComposingText: false,
            triggerReason: .automatic
        )
    }
}

// MARK: - Mocks

@MainActor
private final class CapturedLineSuggestions: @unchecked Sendable {
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
private final class TestLineInferenceService: CompletionInferring {
    enum Response {
        case immediate(String)
        case delayed(String, UInt64)
    }

    var responses: [Response] = []

    func infer(for request: InlineCompletionRequest, settings: InlineCompletionSettings) async throws -> InlineCompletionResult? {
        guard !responses.isEmpty else { return nil }
        let response = responses.removeFirst()
        switch response {
        case .immediate(let text):
            return InlineCompletionResult(requestId: request.requestId, suggestionText: text, confidenceScore: 0.8, source: .local, latencyMs: 10)
        case .delayed(let text, let delay):
            try? await Task.sleep(nanoseconds: delay)
            return InlineCompletionResult(requestId: request.requestId, suggestionText: text, confidenceScore: 0.8, source: .local, latencyMs: Double(delay) / 1_000_000)
        }
    }
}

@MainActor
private final class LineTestSettingsStore: InlineCompletionSettingsStore {
    override func load() -> InlineCompletionSettings {
        InlineCompletionSettings(
            isEnabled: true, debounceMilliseconds: 0, aggressiveness: 0.6,
            maxSuggestionLength: 200, multilineEnabled: false,
            retrievalEnabled: false, routingMode: .localOnly, debugOverlayEnabled: false
        )
    }
}
