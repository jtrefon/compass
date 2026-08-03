import XCTest
@testable import Compass

@MainActor
final class ConversationPolicyTests: XCTestCase {

    private let policy = ConversationPolicy()

    private func makeTool(name: String) -> StubTool {
        StubTool(name: name)
    }

    private var allTools: [AITool] {
        [
            makeTool(name: "glob"),
            makeTool(name: "ls"),
            makeTool(name: "search"),
            makeTool(name: "read"),
            makeTool(name: "context"),
            makeTool(name: "write"),
            makeTool(name: "edit"),
            makeTool(name: "bash")
        ]
    }

    private let expectedReadOnly: Set<String> = [
        "glob",
        "ls",
        "search",
        "read",
        "context"
    ]
    private let expectedToolLoopExecution: Set<String> = [
        "glob",
        "ls",
        "search",
        "read",
        "context",
        "write",
        "edit",
        "bash"
    ]

    // MARK: - Chat mode

    func testChatModeReturnsReadOnlyToolsRegardlessOfStage() {
        let stages: [AIRequestStage?] = [nil, .initial_response, .tool_loop, .final_response, .qa_tool_output_review, .qa_quality_review]
        let mutationTools: Set<String> = ["write", "edit", "bash", "rm"]
        for stage in stages {
            let result = policy.allowedTools(for: stage, mode: .chat, from: allTools)
            XCTAssertFalse(result.isEmpty, "Chat mode should return read-only tools for stage=\(String(describing: stage))")
            // Chat mode excludes mutation tools
            for tool in result {
                XCTAssertFalse(mutationTools.contains(tool.name), "Chat mode should not include mutation tool: \(tool.name)")
            }
        }
    }

    // MARK: - Agent mode: full tool access stages

    func testAgentModeNilStageReturnsAllTools() {
        let result = policy.allowedTools(for: nil, mode: .agent, from: allTools)
        XCTAssertEqual(result.count, allTools.count)
    }

    func testAgentModeInitialResponseReturnsExecutionToolsOnly() {
        let result = policy.allowedTools(for: .initial_response, mode: .agent, from: allTools)
        let names = Set(result.map(\.name))
        XCTAssertEqual(
            names,
            expectedToolLoopExecution,
            "initial_response must keep the same execution-capable tool subset as the tool loop"
        )
    }

    func testAgentModeToolLoopReturnsExecutionToolsOnly() {
        let result = policy.allowedTools(for: .tool_loop, mode: .agent, from: allTools)
        let names = Set(result.map(\.name))
        XCTAssertEqual(names, expectedToolLoopExecution)
    }

    func testReasoningPromptKeyUsesToolLoopSpecificPromptOnlyForToolLoopStage() {
        XCTAssertEqual(
            AIRequestStage.tool_loop.reasoningPromptKey,
            "ConversationFlow/Corrections/reasoning_optional_tool_loop"
        )
        XCTAssertEqual(
            AIRequestStage.reasoningPromptKey(for: .tool_loop),
            "ConversationFlow/Corrections/reasoning_optional_tool_loop"
        )
        XCTAssertEqual(
            AIRequestStage.final_response.reasoningPromptKey,
            "ConversationFlow/Corrections/reasoning_optional_general"
        )
        XCTAssertEqual(
            AIRequestStage.reasoningPromptKey(for: nil),
            "ConversationFlow/Corrections/reasoning_optional_general"
        )
        // Stage-independent by design: the system prompt must be byte-identical
        // across stages so the provider prefix cache stays warm. Agent mode with
        // agent reasoning now returns the general key for every stage (never nil).
        XCTAssertEqual(
            AIRequestStage.reasoningPromptKeyIfNeeded(
                reasoningMode: .modelAndAgent,
                mode: .agent,
                stage: .tool_loop
            ),
            "ConversationFlow/Corrections/reasoning_optional_general"
        )
        XCTAssertNil(
            AIRequestStage.reasoningPromptKeyIfNeeded(
                reasoningMode: .none,
                mode: .agent,
                stage: .tool_loop
            )
        )
        XCTAssertNil(
            AIRequestStage.reasoningPromptKeyIfNeeded(
                reasoningMode: .modelAndAgent,
                mode: .chat,
                stage: .tool_loop
            )
        )
        XCTAssertEqual(
            AIRequestStage.reasoningPromptKeyIfNeeded(
                reasoningMode: .modelAndAgent,
                mode: .agent,
                stage: .initial_response
            ),
            "ConversationFlow/Corrections/reasoning_optional_general"
        )
        XCTAssertEqual(
            AIRequestStage.other.reasoningPromptKey,
            "ConversationFlow/Corrections/reasoning_optional_general"
        )
    }

    func testAgentModeFinalResponseReturnsAllTools() {
        let result = policy.allowedTools(for: .final_response, mode: .agent, from: allTools)
        XCTAssertEqual(result.count, allTools.count)
    }

    // MARK: - Agent mode: QA stages (read-only)

    // MARK: - Agent mode: QA stages (read-only)

    func testAgentModeQAToolOutputReviewReturnsReadOnlyTools() {
        let result = policy.allowedTools(for: .qa_tool_output_review, mode: .agent, from: allTools)
        let names = Set(result.map(\.name))
        XCTAssertEqual(names, expectedReadOnly)
    }

    func testAgentModeQAQualityReviewReturnsReadOnlyTools() {
        let result = policy.allowedTools(for: .qa_quality_review, mode: .agent, from: allTools)
        let names = Set(result.map(\.name))
        XCTAssertEqual(names, expectedReadOnly)
    }

    func testAgentModeReadOnlyStageExcludesWriteTools() {
        let result = policy.allowedTools(for: .qa_tool_output_review, mode: .agent, from: allTools)
        let names = result.map(\.name)
        XCTAssertFalse(names.contains("write"))
        XCTAssertFalse(names.contains("edit"))
        XCTAssertFalse(names.contains("bash"))
    }

    // MARK: - Edge cases

    func testEmptyToolListReturnsEmpty() {
        let result = policy.allowedTools(for: .tool_loop, mode: .agent, from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testQAStageWithNoReadOnlyToolsReturnsEmpty() {
        let writeOnly: [AITool] = [makeTool(name: "write"), makeTool(name: "bash")]
        let result = policy.allowedTools(for: .qa_tool_output_review, mode: .agent, from: writeOnly)
        XCTAssertTrue(result.isEmpty)
    }
}

private struct StubTool: AITool {
    let name: String
    let description: String = "stub"

    var parameters: [String: Any] {
        ["type": "object", "properties": [:]]
    }

    func execute(arguments _: ToolArguments) async throws -> String {
        "ok"
    }
}
