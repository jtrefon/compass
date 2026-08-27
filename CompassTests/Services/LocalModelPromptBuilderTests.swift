import XCTest
@testable import Compass

final class LocalModelPromptBuilderTests: XCTestCase {
    func testBudgetMessagesUsesCumulativeHistoryBudget() {
        let config = LocalModelInferenceConfiguration(
            contextLength: 1_000,
            maxKVSize: 1_000,
            maxOutputTokens: 100,
            prefillStepSize: 512,
            temperature: 0.2,
            topP: 0.9,
            repetitionPenalty: nil,
            repetitionContextSize: 64,
            kvCache4BitEnabled: true
        )
        let messages = [
            ChatMessage(role: .user, content: String(repeating: "a", count: 300)),
            ChatMessage(role: .assistant, content: String(repeating: "b", count: 300)),
            ChatMessage(role: .user, content: String(repeating: "c", count: 300)),
        ]

        let result = LocalModelPromptBuilder().budgetMessages(
            messages,
            explicitContext: nil,
            systemContent: String(repeating: "s", count: 100),
            inferenceConfiguration: config,
            approximateTokenCount: { $0.count }
        )

        XCTAssertEqual(result.map(\.content), [messages[2].content])
    }

    func testBudgetMessagesPreservesStrictChronologicalOrderWithToolExchanges() {
        let config = LocalModelInferenceConfiguration(
            contextLength: 10_000,
            maxKVSize: 10_000,
            maxOutputTokens: 100,
            prefillStepSize: 512,
            temperature: 0.2,
            topP: 0.9,
            repetitionPenalty: nil,
            repetitionContextSize: 64,
            kvCache4BitEnabled: true
        )

        let toolCall1 = AIToolCall(id: "call-1", name: "ls", arguments: ["path": "."])
        let toolCall2 = AIToolCall(id: "call-2", name: "read", arguments: ["path": "file.txt"])

        let messages = [
            ChatMessage(role: .user, content: "U1: List files"),
            ChatMessage(
                role: .assistant,
                content: "",
                tool: ChatMessageToolContext(toolCalls: [toolCall1])
            ),
            ChatMessage(
                role: .tool,
                content: "T1: file1, file2",
                tool: ChatMessageToolContext(
                    toolName: "ls",
                    toolStatus: .completed,
                    target: ToolInvocationTarget(toolCallId: "call-1")
                )
            ),
            ChatMessage(role: .assistant, content: "A1: Found files"),
            ChatMessage(role: .user, content: "U2: Read file"),
            ChatMessage(
                role: .assistant,
                content: "",
                tool: ChatMessageToolContext(toolCalls: [toolCall2])
            ),
            ChatMessage(
                role: .tool,
                content: "T2: content of file",
                tool: ChatMessageToolContext(
                    toolName: "read",
                    toolStatus: .completed,
                    target: ToolInvocationTarget(toolCallId: "call-2")
                )
            ),
        ]

        let result = LocalModelPromptBuilder().budgetMessages(
            messages,
            explicitContext: nil,
            systemContent: "system prompt",
            inferenceConfiguration: config,
            approximateTokenCount: { $0.count }
        )

        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result[0].content, "U1: List files")
        XCTAssertEqual(result[1].role, .assistant)
        XCTAssertEqual(result[1].toolCalls?.first?.id, "call-1")
        XCTAssertEqual(result[2].role, .tool)
        XCTAssertEqual(result[2].content, "T1: file1, file2")
        XCTAssertEqual(result[3].content, "A1: Found files")
        XCTAssertEqual(result[4].content, "U2: Read file")
        XCTAssertEqual(result[5].role, .assistant)
        XCTAssertEqual(result[5].toolCalls?.first?.id, "call-2")
        XCTAssertEqual(result[6].role, .tool)
        XCTAssertEqual(result[6].content, "T2: content of file")
    }

    func testBuildRawMessagesIncludesToolCallIdAndNameForToolRole() {
        let toolCall = AIToolCall(id: "tool-call-123", name: "bash", arguments: ["command": "ls"])
        let messages = [
            ChatMessage(role: .user, content: "run ls"),
            ChatMessage(
                role: .assistant,
                content: "",
                tool: ChatMessageToolContext(toolCalls: [toolCall])
            ),
            ChatMessage(
                role: .tool,
                content: "file1\nfile2",
                tool: ChatMessageToolContext(
                    toolName: "bash",
                    toolStatus: .completed,
                    target: ToolInvocationTarget(toolCallId: "tool-call-123")
                )
            )
        ]

        let raw = LocalModelPromptBuilder().buildRawMessages(
            messages: messages,
            explicitContext: nil,
            systemContent: "System instructions"
        )

        XCTAssertEqual(raw.count, 4) // System + User + Assistant + Tool
        let toolRaw = raw[3]
        XCTAssertEqual(toolRaw["role"] as? String, "tool")
        XCTAssertEqual(toolRaw["name"] as? String, "bash")
        XCTAssertEqual(toolRaw["tool_call_id"] as? String, "tool-call-123")
        XCTAssertEqual(toolRaw["content"] as? String, "file1\nfile2")
    }
}
