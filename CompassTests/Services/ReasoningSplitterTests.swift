import XCTest
@testable import Compass

final class ReasoningSplitterTests: XCTestCase {

    func testSplitsThinkBlockIntoReasoning() {
        let response = AIServiceResponse(
            content: "<think>Let me check the code</think>\nThe answer is 42.",
            toolCalls: nil,
            reasoning: nil
        )
        let split = ReasoningSplitter.apply(to: response)
        XCTAssertEqual(split.content, "The answer is 42.")
        XCTAssertEqual(split.reasoning, "Let me check the code")
    }

    func testPreservesContentBeforeThinkTag() {
        let response = AIServiceResponse(
            content: "Looking at the file.\n<think>It uses a map</think>\nThe result is a map.",
            toolCalls: nil,
            reasoning: nil
        )
        let split = ReasoningSplitter.apply(to: response)
        XCTAssertEqual(split.content, "Looking at the file.\n\nThe result is a map.")
        XCTAssertEqual(split.reasoning, "It uses a map")
    }

    func testPassesThroughProviderReasoningUnchanged() {
        let response = AIServiceResponse(
            content: "A direct answer with <think>leftover</think> markup.",
            toolCalls: nil,
            reasoning: "Provider-set reasoning"
        )
        let split = ReasoningSplitter.apply(to: response)
        XCTAssertEqual(split.content, "A direct answer with <think>leftover</think> markup.")
        XCTAssertEqual(split.reasoning, "Provider-set reasoning")
    }

    func testNoThinkBlockPassesThrough() {
        let response = AIServiceResponse(
            content: "Plain answer without thinking.",
            toolCalls: nil,
            reasoning: nil
        )
        let split = ReasoningSplitter.apply(to: response)
        XCTAssertEqual(split.content, "Plain answer without thinking.")
        XCTAssertNil(split.reasoning)
    }

    func testNilContent() {
        let response = AIServiceResponse(content: nil, toolCalls: nil, reasoning: nil)
        let split = ReasoningSplitter.apply(to: response)
        XCTAssertNil(split.content)
        XCTAssertNil(split.reasoning)
    }
}
