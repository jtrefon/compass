import XCTest
import Combine
@testable import Compass

@MainActor
final class AgentLoopTests: XCTestCase {

    private func makeContext(tempDir: URL) async -> (history: ChatHistoryCoordinator, loop: AgentLoop, mock: QueueToolMockService) {
        let eventBus = EventBus()
        let executor = AIToolExecutor(
            fileSystemService: FileSystemService(),
            errorManager: ToolRetryErrorManager(),
            projectRoot: tempDir,
            eventBus: eventBus
        )
        let coord = ToolExecutionCoordinator(executor: executor)
        let history = ChatHistoryCoordinator(eventBus: eventBus)
        let mock = QueueToolMockService(responses: [])
        let aiCoord = AIInteractionCoordinator(aiService: mock, codebaseIndex: nil, eventBus: eventBus)
        let tools: [AITool] = [PatchFileToolAdapter(projectRoot: tempDir), ReadFileTool(fileSystemService: FileSystemService(), pathValidator: PathValidator(projectRoot: tempDir))]
        let request = SendRequest(
            userInput: "refactor sample.php",
            mode: .coder,
            projectRoot: tempDir,
            conversationId: "conv-1",
            runId: "run-1",
            availableTools: tools,
            draftAssistantMessageId: nil
        )
        let loop = AgentLoop(
            aiCoordinator: aiCoord,
            historyCoordinator: history,
            toolExecutor: coord,
            projectRoot: tempDir,
            request: request,
            classification: .build
        )
        return (history, loop, mock)
    }

    /// A failed edit (error-string result) must loop the leaf back with the
    /// error in context — the observed production failure ended the run on
    /// the model's apology ("I missed providing the old_string").
    /// A failed edit (error-string result) must loop the leaf back with the
    /// error in context — the observed production failure ended the run on
    /// the model's apology ("I missed providing the old_string").
    ///
    /// NOTE on queue layout: the build path's architect phase PASSTHROUGHES
    /// the researcher's conversational answer, so it never consumes a mock
    /// response — the leaf is the second call, not the third.
    func testFailedEditLoopsLeafBackForRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent_loop_retry_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let target = tempDir.appendingPathComponent("sample.php")
        try "<?php\nclass Sample { public function run() {} }\n".write(to: target, atomically: true, encoding: .utf8)

        let (history, loop, mock) = await makeContext(tempDir: tempDir)

        // Researcher answers conversationally (architect passes it through);
        // the leaf then attempts an edit WITHOUT old_string/new_string (the
        // exact session failure) — the REAL PatchFileToolAdapter returns a
        // MISSING_ARGUMENTS error string; the retry produces the final answer.
        mock.queue(responses: [
            AIServiceResponse(content: "Exploring the project structure.", toolCalls: nil),
            AIServiceResponse(content: "", toolCalls: [AIToolCall(id: "call_edit", name: "edit",
                                                                  arguments: ["path": target.path, "new_content": "<?php\n"])]),
            AIServiceResponse(content: "Refactor applied successfully.", toolCalls: nil),
        ])

        let result = try await loop.run()

        XCTAssertGreaterThanOrEqual(mock.calls, 5, "The failed edit must trigger a retry call")
        // The edit's error text must be visible in the history (model context).
        let historyText = history.requestMessages.map { $0.content }.joined()
        XCTAssertTrue(historyText.contains("MISSING_ARGUMENTS"),
                      "The tool error must be in the model's context for the retry")
        XCTAssertNotNil(result.content)
    }

    /// A model that keeps requesting tools (no answer) must terminate through
    /// the loop's guards (visit budgets, retry caps, transition budget) and
    /// still produce a final summary — no hang, no throw.
    func testAlwaysToolCallingModelCompletesWithinBudget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent_loop_budget_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (history, loop, mock) = await makeContext(tempDir: tempDir)
        mock.alwaysReturns = AIServiceResponse(
            content: "",
            toolCalls: [AIToolCall(id: "call_read", name: "read", arguments: ["path": "missing.php"])]
        )

        let result = try await loop.run()

        XCTAssertNotNil(result.content, "The run must end with a visible answer")
        XCTAssertLessThan(mock.calls, AgentLoop.maxTransitions,
                          "Loop guards must keep the run bounded")
        let toolMessages = history.requestMessages.filter { $0.role == .tool }
        XCTAssertFalse(toolMessages.isEmpty,
                       "Tool executions must be committed to history")
    }

    /// A conversational answer on the fast path returns directly with a
    /// single model call — no tool loop, no phase churn.
    func testFastPathSingleCall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent_loop_fast_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventBus = EventBus()
        let history = ChatHistoryCoordinator(eventBus: eventBus)
        let mock = QueueToolMockService(responses: [
            AIServiceResponse(content: "Hello! How can I help?", toolCalls: nil)
        ])
        let aiCoord = AIInteractionCoordinator(aiService: mock, codebaseIndex: nil, eventBus: eventBus)
        let tools: [AITool] = [PatchFileToolAdapter(projectRoot: tempDir)]
        let request = SendRequest(
            userInput: "hello",
            mode: .coder,
            projectRoot: tempDir,
            conversationId: "conv-fast",
            runId: "run-fast",
            availableTools: tools,
            draftAssistantMessageId: nil
        )
        let loop = AgentLoop(
            aiCoordinator: aiCoord,
            historyCoordinator: history,
            toolExecutor: ToolExecutionCoordinator(executor: AIToolExecutor(
                fileSystemService: FileSystemService(),
                errorManager: ToolRetryErrorManager(),
                projectRoot: tempDir
            )),
            projectRoot: tempDir,
            request: request,
            classification: .fast
        )

        let result = try await loop.run()

        XCTAssertEqual(result.content, "Hello! How can I help?")
        XCTAssertEqual(mock.calls, 1, "Fast path must be a single model call")
    }
}

/// Mock AIService returning queued responses in order (or a repeat response
/// when the queue is empty and `alwaysReturns` is set).
private final class QueueToolMockService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
    var alwaysReturns: AIServiceResponse?
    private let lock = NSLock()
    private var queue: [AIServiceResponse]
    var calls = 0

    init(responses: [AIServiceResponse]) {
        self.queue = responses
    }

    func queue(responses: [AIServiceResponse]) {
        lock.lock()
        queue.append(contentsOf: responses)
        lock.unlock()
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        next()
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        next()
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        next()
    }

    private func next() -> AIServiceResponse {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if queue.isEmpty {
            if let alwaysReturns { return alwaysReturns }
            return AIServiceResponse(content: "Mock response", toolCalls: nil)
        }
        return queue.removeFirst()
    }
}

private final class ToolRetryErrorManager: ErrorManagerProtocol {
    var currentError: AppError?
    var showErrorAlert: Bool = false
    func handle(_ error: AppError) { currentError = error }
    func handle(_ error: Error, context: String) {}
    func dismissError() { showErrorAlert = false }
    var statePublisher: ObservableObjectPublisher { objectWillChange }
}
