import XCTest
import Foundation
@testable import Compass

final class ChatPromptBuilderReasoningTests: XCTestCase {
    func testSplitReasoning_extractsBlockAndCleansContent() {
        let input = """
        Reflection:
        - What: A
        Planning:
        - What: B
        Continuity: D

        Hello world
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertNotNil(split.reasoning)
        XCTAssertTrue(split.reasoning?.contains("Reflection:") == true)
        XCTAssertEqual(split.content, "Hello world")
    }

    func testSplitReasoningDoesNotStripPlainContentWithoutLeadingReasoningBlock() {
        let input = """
        Visible one
        Visible two
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Visible one\nVisible two")
        XCTAssertNil(split.reasoning)
    }

    func testSplitReasoning_stripsPlainLeadingReasoningBlockFromVisibleContent() {
        let input = """
        Reflection: Working
        Planning: Working
        Continuity: Stable

        Before content
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Before content")
        XCTAssertTrue(split.reasoning?.contains("Reflection: Working") == true)
    }

    func testSplitReasoning_extractsThinkingTagAndCleansContent() {
        let input = """
        <thinking>
        Reflection: A
        Planning: B
        Continuity: C
        </thinking>

        Visible answer
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Visible answer")
        XCTAssertEqual(split.reasoning, "Reflection: A\nPlanning: B\nContinuity: C")
    }

    func testSplitReasoning_extractsThinkTagAndCleansContent() {
        let input = """
        <think>
        Reflection: A
        Planning: B
        Continuity: C
        </think>

        Visible answer
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Visible answer")
        XCTAssertEqual(split.reasoning, "Reflection: A\nPlanning: B\nContinuity: C")
    }

    func testSplitReasoning_extractsLegacyIdeReasoningTagAndCleansContent() {
        let input = """
        <ide_reasoning>
        Reflection: A
        Planning: B
        Continuity: C
        </ide_reasoning>

        Visible answer
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Visible answer")
        XCTAssertEqual(split.reasoning, "Reflection: A\nPlanning: B\nContinuity: C")
    }

    func testSplitReasoning_extractsReasoningWhenOpeningThinkTagIsMissing() {
        let input = """
        Reflection: A
        Planning: B
        Continuity: C
        </think>

        Visible answer
        """

        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Visible answer")
        XCTAssertEqual(split.reasoning, "Reflection: A\nPlanning: B\nContinuity: C")
    }

    func testSplitReasoningLeavesInlineContentUntouchedWithoutTaggedMarkupSupport() {
        let input = "Alpha Reflection: R Beta"
        let split = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(split.content, "Alpha Reflection: R Beta")
        XCTAssertNil(split.reasoning)
    }

    func testReasoningForDisplay_insertsBreaksForCollapsedSectionLabels() {
        let input = "Codebase Review & InsightsArchitecture: Storage Layer. UI Layer: React. Routing: SPA. Strengths: Clean. Potential Issues: None. Recommendations: Ship. Remaining Work: None. Status: Complete."

        let output = ChatPromptBuilder.reasoningForDisplay(input)

        XCTAssertTrue(output.contains("Codebase Review & Insights\n\nArchitecture: Storage Layer."))
        XCTAssertTrue(output.contains("\n\nUI Layer: React."))
        XCTAssertTrue(output.contains("\n\nRouting: SPA."))
        XCTAssertTrue(output.contains("\n\nStrengths: Clean."))
        XCTAssertTrue(output.contains("\n\nPotential Issues: None."))
        XCTAssertTrue(output.contains("\n\nRecommendations: Ship."))
        XCTAssertTrue(output.contains("\n\nRemaining Work: None."))
        XCTAssertTrue(output.contains("\n\nStatus: Complete."))
    }

    func testContentForDisplayStripsSupportedXMLToolCallMarkup() {
        let input = """
        <tool_call>read_file
        <arg_key>path</arg_key>
        <arg_value>prisma/schema.prisma</arg_value>
        </tool_call>
        Done exploring structure.
        """

        let output = ChatPromptBuilder.contentForDisplay(from: input)
        XCTAssertFalse(output.contains("<tool_call>"))
        XCTAssertFalse(output.contains("<arg_key>"))
        XCTAssertFalse(output.contains("<arg_value>"))
        XCTAssertTrue(output.contains("Done exploring structure."))
    }
}
