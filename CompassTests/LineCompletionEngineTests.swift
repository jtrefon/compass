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

    // MARK: - Adaptive token budget (FIM_Spec.md §5)

    func test_engine_adaptiveBudget_scalesWithTypingGap() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("a"), .immediate("b"), .immediate("c"), .immediate("d")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        // Pause → full budget.
        engine.requestCompletion(for: snapshot(buffer: "foo", cursor: 3), gapMs: 400, typedChar: "o")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(inference.lastRequestMaxTokens, 64, "pause should get the full budget")

        // Mid-speed → 16.
        engine.requestCompletion(for: snapshot(buffer: "foo1", cursor: 4), gapMs: 250, typedChar: "1")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(inference.lastRequestMaxTokens, 16, "250ms gap should get 16 tokens")

        // Faster → 8.
        engine.requestCompletion(for: snapshot(buffer: "foo12", cursor: 5), gapMs: 150, typedChar: "2")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(inference.lastRequestMaxTokens, 8, "150ms gap should get 8 tokens")

        // Burst → 4 (trigger char passes the fast-typing gate).
        engine.requestCompletion(for: snapshot(buffer: "foo{", cursor: 4), gapMs: 50, typedChar: "{")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(inference.lastRequestMaxTokens, 4, "burst should get the minimum budget")
    }

    // MARK: - Accept-verify consumes the suggestion head without a model call

    func test_engine_acceptVerify_consumesTypedHeadWithoutModelCall() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("lor: red;")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        // First request produces the suggestion "lor: red;".
        engine.requestCompletion(for: snapshot(buffer: ".foo { c", cursor: 8), gapMs: 400, typedChar: "c")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "lor: red;")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        // User types "l" — matches the head → remainder "or: red;" published,
        // no second model call.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: ".foo { cl", cursor: 9), gapMs: 150, typedChar: "l")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "or: red;", "suggestion head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 1, "accept-verify must not call the model")

        // User deviates ("x") — model is called again with a small budget.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: ".foo { clx", cursor: 10), gapMs: 150, typedChar: "x")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(inference.capturedRequests.count, 2, "deviation should trigger a new model call")
        XCTAssertEqual(inference.lastRequestMaxTokens, 8, "deviation during 150ms gap should use the mid budget")
    }

    // MARK: - Variant pool integration (FIM_VariantPools_Arch.md §5)

    /// Deviation seeds the pool; subsequent head-consumption serves the pool
    /// without any model call.
    func test_engine_deviationSeedsPoolAndPoolHitSkipsInference() async throws {
        let provider = MockVariantProvider()
        let poolService = VariantPoolService(provider: provider)
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("ab"), .immediate("de")]
        let engine = LineCompletionEngine(
            inferenceService: inference,
            variantPoolService: poolService
        )
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        // Step 1: fresh context → inference, no chain (no suggestion context yet).
        engine.requestCompletion(for: snapshot(buffer: "x", cursor: 1), gapMs: 400, typedChar: "x")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(captured.lastSuggestion, "ab")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        // Step 2: typed "a" extends the suggestion head → consumed, no inference.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: "xa", cursor: 2), gapMs: 200, typedChar: "a")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "b", "suggestion head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 1, "no model call on head consumption")

        // Step 3: typed "b" → fully consumed → dismissed, no inference.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: "xab", cursor: 3), gapMs: 200, typedChar: "b")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(captured.lastSuggestion)
        XCTAssertEqual(inference.capturedRequests.count, 1)

        // Step 4: typed "c" → deviation → fresh inference + pool seeded.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: "xabc", cursor: 4), gapMs: 200, typedChar: "c")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(captured.lastSuggestion, "de")
        XCTAssertEqual(inference.capturedRequests.count, 2, "deviation should re-infer")
        let variants = await poolService.variants(paneID: .primary)
        XCTAssertEqual(variants.map(\.text), ["de"], "deviation prediction should seed the pool")

        // Step 5: typed "d" — pool head consumption, no model call.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: "xabcd", cursor: 5), gapMs: 200, typedChar: "d")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "e", "pool variant head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 2, "pool hit must not call the model")
    }

    /// The chain fills the seeded pool with variants from the provider.
    func test_engine_chainFillsSeededPool() async throws {
        let provider = MockVariantProvider()
        provider.texts = ["alt1", "alt2", "alt3"]
        provider.firstTokens = [10, 11, 12]
        let poolService = VariantPoolService(provider: provider)
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("ab"), .immediate("de")]
        inference.firstTokenID = 100
        let engine = LineCompletionEngine(
            inferenceService: inference,
            variantPoolService: poolService
        )
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: "x", cursor: 1), gapMs: 400, typedChar: "x")
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.requestCompletion(for: snapshot(buffer: "xabc", cursor: 4), gapMs: 200, typedChar: "c")
        try await Task.sleep(nanoseconds: 100_000_000)

        let deadline = Date().addingTimeInterval(5)
        var variants: [InlineCompletionVariant] = []
        while Date() < deadline {
            variants = await poolService.variants(paneID: .primary)
            if variants.count == 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(variants.map(\.text), ["de", "alt1", "alt2", "alt3"], "seeded prediction + 3 chained variants")
        XCTAssertEqual(provider.bansSeen.first ?? [], [100], "chained variants must ban the seed's first token")
    }

    /// Consumption must happen BEFORE the gate: even during fast typing
    /// (gapMs below the fast-typing threshold) the suggestion head is served
    /// without a model call — the gate must never clear the ghost first.
    func test_engine_fastTypingStillConsumesSuggestionHead() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("lor: red;")]
        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        engine.requestCompletion(for: snapshot(buffer: ".foo { c", cursor: 8), gapMs: 400, typedChar: "c")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(captured.lastSuggestion, "lor: red;")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        // Fast keystroke extending the head — must consume, not gate-reject.
        captured.reset()
        engine.requestCompletion(for: snapshot(buffer: ".foo { cl", cursor: 9), gapMs: 50, typedChar: "l")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(captured.lastSuggestion, "or: red;", "fast typing must still consume the head")
        XCTAssertEqual(inference.capturedRequests.count, 1, "no model call on consumption")
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
private final class LineTestSettingsStore: InlineCompletionSettingsStore {
    override func load() -> InlineCompletionSettings {
        InlineCompletionSettings(
            isEnabled: true, debounceMilliseconds: 0, aggressiveness: 0.6,
            maxSuggestionLength: 200, debugOverlayEnabled: false
        )
    }
}
