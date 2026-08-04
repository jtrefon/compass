import XCTest
@testable import Compass

@MainActor
final class ChatMessageVisibilityPolicyTests: XCTestCase {
    func testSyntheticDoneNextAssistantProgressMessageIsHidden() {
        let message = ChatMessage(
            role: .assistant,
            content: "Done -> Next -> Path: Continue with remaining implementation."
        )

        XCTAssertFalse(ChatMessageVisibilityPolicy.shouldDisplayMessage(message))
        XCTAssertTrue(ChatMessageVisibilityPolicy.isSyntheticAssistantProgressMessage(message))
    }

    func testTripletReasoningProgressMessageIsHidden() {
        let message = ChatMessage(
            role: .assistant,
            content: "Implementation inspected. Next: applying targeted code changes in src/App.tsx.",
            context: ChatMessageContentContext(
                reasoning: """
                What: Implementation inspected
                How: applying targeted code changes
                Where: src/App.tsx
                """
            )
        )

        XCTAssertFalse(ChatMessageVisibilityPolicy.shouldDisplayMessage(message))
    }

    func testSyntheticDraftAssistantProgressMessageIsHidden() {
        let message = ChatMessage(
            role: .assistant,
            content: "Done -> Next -> Path: Continue with remaining implementation.",
            isDraft: true
        )

        XCTAssertFalse(ChatMessageVisibilityPolicy.shouldDisplayMessage(message))
        XCTAssertTrue(ChatMessageVisibilityPolicy.isSyntheticAssistantProgressMessage(message))
    }

    func testAssistantToolCallProgressMessageWithNextClauseIsHidden() {
        let message = ChatMessage(
            role: .assistant,
            content: "The lint script is missing. Let me add one and run ESLint: Next: reviewing package.json.",
            tool: ChatMessageToolContext(
                toolCalls: [AIToolCall(id: "tool-1", name: "read_file", arguments: ["path": "package.json"])]
            )
        )

        XCTAssertFalse(ChatMessageVisibilityPolicy.shouldDisplayMessage(message))
        XCTAssertTrue(ChatMessageVisibilityPolicy.isSyntheticAssistantProgressMessage(message))
    }

    func testNormalFinalAssistantMessageRemainsVisible() {
        let message = ChatMessage(
            role: .assistant,
            content: "Implemented the remaining role support work and verified the affected flow."
        )

        XCTAssertTrue(ChatMessageVisibilityPolicy.shouldDisplayMessage(message))
        XCTAssertFalse(ChatMessageVisibilityPolicy.isSyntheticAssistantProgressMessage(message))
    }

    func testMessageFilterCoordinatorRemovesSyntheticDraftMessages() {
        let coordinator = MessageFilterCoordinator()
        let messages = [
            ChatMessage(role: .user, content: "Implement the remaining work."),
            ChatMessage(
                role: .assistant,
                content: "Done -> Next -> Path: Continue with remaining implementation.",
                isDraft: true
            ),
            ChatMessage(
                role: .assistant,
                content: "Implemented the remaining role support work and verified the affected flow."
            )
        ]

        let visible = coordinator.filterMessages(messages)

        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.map(\.content), [
            "Implement the remaining work.",
            "Implemented the remaining role support work and verified the affected flow."
        ])
    }
}
