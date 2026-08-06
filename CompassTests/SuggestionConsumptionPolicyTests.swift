import XCTest
@testable import Compass

final class SuggestionConsumptionPolicyTests: XCTestCase {
    private func variant(_ text: String, rank: Double = 0.5) -> InlineCompletionVariant {
        InlineCompletionVariant(
            id: UUID(), text: text, temperature: 0.1,
            bannedTokenCount: 0, createdAt: Date(), rankScore: rank
        )
    }

    func testMatchesHeadAndReturnsRemainder() {
        let result = SuggestionConsumptionPolicy.consume(
            from: [variant("lugin->method();")],
            bufferBeforeCursor: "    $pl"
        )
        XCTAssertEqual(result?.remainder, "ugin->method();")
    }

    func testFullConsumptionReturnsNilRemainder() {
        let result = SuggestionConsumptionPolicy.consume(
            from: [variant("plugin")],
            bufferBeforeCursor: "$plugin"
        )
        XCTAssertNotNil(result)
        XCTAssertNil(result?.remainder, "fully typed suggestion has no remainder")
    }

    func testNoMatchReturnsNil() {
        let result = SuggestionConsumptionPolicy.consume(
            from: [variant("plugin")],
            bufferBeforeCursor: "function foo"
        )
        XCTAssertNil(result)
    }

    func testEmptyCandidatesReturnNil() {
        XCTAssertNil(SuggestionConsumptionPolicy.consume(from: [], bufferBeforeCursor: "$p"))
    }

    func testPicksFirstRankedCandidate() {
        // Both candidates share the head; the higher-ranked one wins.
        let result = SuggestionConsumptionPolicy.consume(
            from: [variant("lugin->method();", rank: 0.9), variant("lugout();", rank: 0.3)],
            bufferBeforeCursor: "    $plu"
        )
        XCTAssertEqual(result?.consumedText, "lugin->method();")
        XCTAssertEqual(result?.remainder, "gin->method();")
    }

    func testLongestHeadMatchWins() {
        // Buffer ends with "plu" — both "plu" (3) and "u" (1) match; longest wins.
        let result = SuggestionConsumptionPolicy.consume(
            from: [variant("plugin")],
            bufferBeforeCursor: "    $plu"
        )
        XCTAssertEqual(result?.remainder, "gin")
    }
}
