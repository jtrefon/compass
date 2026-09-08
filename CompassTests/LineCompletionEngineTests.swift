import XCTest
@testable import Compass

@MainActor
final class LineCompletionEngineTests: XCTestCase {

    func test_engine_immediateRequest_returnsSuggestion() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("color: red;")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        let exp = expectation(description: "suggestion received")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo {\n    colo", cursor: 14), gapMs: 200, typedChar: "o")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "color: red;")
    }

    func test_engine_noResponse_publishesNil() async throws {
        let inference = TestLineInferenceService()
        inference.responses = []

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        let exp = expectation(description: "suggestion received")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo", cursor: 3), gapMs: 200, typedChar: "o")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(captured.lastSuggestion)
    }

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

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-fam", cursor: 16), gapMs: 200, typedChar: "m")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "font-family: serif;", "First request should succeed")

        engine.markAccepted(on: .primary, suggestionText: captured.lastSuggestion)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-family: serif;\n    colo", cursor: 40), gapMs: 200, typedChar: "o")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "color: blue;", "Second request after accept should succeed")

        engine.markAccepted(on: .primary, suggestionText: captured.lastSuggestion)

        captured.reset()
        exp = expectation(description: "suggestion 3")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".a {\n    font-family: serif;\n    color: blue;\n    backg", cursor: 63), gapMs: 200, typedChar: "g")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "background: white;", "Third request after two accepts should succeed")
    }

    func test_engine_lateRequestWins_overEarlySlowRequest() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [
            .delayed("old", 200_000_000),
            .immediate("new")
        ]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        let exp = expectation(description: "suggestion received")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "first", cursor: 5), gapMs: 200, typedChar: "t")
        engine.requestCompletion(for: snapshot(buffer: "second", cursor: 6), gapMs: 200, typedChar: "d")

        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(captured.lastSuggestion, "new", "Later request result should win")
    }

    func test_engine_contextualFilter_suppressesClosingParen() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("will not show")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        let exp = expectation(description: "suggestion received")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo)", cursor: 4), gapMs: 0, typedChar: ")")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(captured.lastSuggestion, "Contextual filter should suppress on )")
    }

    func test_engine_adaptiveBudget_scalesWithTypingGap() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("a"), .immediate("b"), .immediate("c"), .immediate("d")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo", cursor: 3), gapMs: 400, typedChar: "o")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(inference.lastRequestMaxTokens, 64, "pause should get the full budget")

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo1", cursor: 4), gapMs: 250, typedChar: "1")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(inference.lastRequestMaxTokens, 16, "250ms gap should get 16 tokens")

        captured.reset()
        exp = expectation(description: "suggestion 3")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo12", cursor: 5), gapMs: 150, typedChar: "2")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(inference.lastRequestMaxTokens, 8, "150ms gap should get 8 tokens")

        captured.reset()
        exp = expectation(description: "suggestion 4")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "foo{", cursor: 4), gapMs: 50, typedChar: "{")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(inference.lastRequestMaxTokens, 4, "burst should get the minimum budget")
    }

    func test_engine_acceptVerify_consumesTypedHeadWithoutModelCall() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("lor: red;")]

        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { c", cursor: 8), gapMs: 400, typedChar: "c")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "lor: red;")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { cl", cursor: 9), gapMs: 150, typedChar: "l")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "or: red;", "suggestion head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 1, "accept-verify must not call the model")

        captured.reset()
        exp = expectation(description: "suggestion 3")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { clx", cursor: 10), gapMs: 150, typedChar: "x")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(inference.capturedRequests.count, 2, "deviation should trigger a new model call")
        XCTAssertEqual(inference.lastRequestMaxTokens, 8, "deviation during 150ms gap should use the mid budget")
    }

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

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "x", cursor: 1), gapMs: 400, typedChar: "x")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "ab")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "xa", cursor: 2), gapMs: 200, typedChar: "a")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "b", "suggestion head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 1, "no model call on head consumption")

        captured.reset()
        exp = expectation(description: "suggestion 3")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "xab", cursor: 3), gapMs: 200, typedChar: "b")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(captured.lastSuggestion)
        XCTAssertEqual(inference.capturedRequests.count, 1)

        captured.reset()
        exp = expectation(description: "suggestion 4")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "xabc", cursor: 4), gapMs: 200, typedChar: "c")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "de")
        XCTAssertEqual(inference.capturedRequests.count, 2, "deviation should re-infer")
        let variants = await poolService.variants(paneID: .primary)
        XCTAssertEqual(variants.map(\.text), ["de"], "deviation prediction should seed the pool")

        captured.reset()
        exp = expectation(description: "suggestion 5")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "xabcd", cursor: 5), gapMs: 200, typedChar: "d")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "e", "pool variant head should be consumed")
        XCTAssertEqual(inference.capturedRequests.count, 2, "pool hit must not call the model")
    }

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

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "x", cursor: 1), gapMs: 400, typedChar: "x")
        await fulfillment(of: [exp], timeout: 2)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: "xabc", cursor: 4), gapMs: 200, typedChar: "c")
        await fulfillment(of: [exp], timeout: 2)

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

    func test_engine_fastTypingStillConsumesSuggestionHead() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("lor: red;")]
        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { c", cursor: 8), gapMs: 400, typedChar: "c")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "lor: red;")
        XCTAssertEqual(inference.capturedRequests.count, 1)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { cl", cursor: 9), gapMs: 50, typedChar: "l")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "or: red;", "fast typing must still consume the head")
        XCTAssertEqual(inference.capturedRequests.count, 1, "no model call on consumption")
    }

    func test_engine_consumptionWorksAfterLongGap() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("lor: red;")]
        let engine = makeEngine(inference: inference)
        let captured = CapturedLineSuggestions()
        engine.registerSuggestionHandler(for: .primary) { captured.set($0) }

        var exp = expectation(description: "suggestion 1")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { c", cursor: 8), gapMs: 400, typedChar: "c")
        await fulfillment(of: [exp], timeout: 2)

        captured.reset()
        exp = expectation(description: "suggestion 2")
        captured.onSet = { exp.fulfill() }

        engine.requestCompletion(for: snapshot(buffer: ".foo { cl", cursor: 9), gapMs: 400, typedChar: "l")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured.lastSuggestion, "or: red;", "consumption must work regardless of elapsed time")
        XCTAssertEqual(inference.capturedRequests.count, 1, "no model call on consumption")
    }

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