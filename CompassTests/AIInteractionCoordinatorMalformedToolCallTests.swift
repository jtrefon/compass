import XCTest
import Combine
@testable import Compass

@MainActor
final class AIInteractionCoordinatorMalformedToolCallTests: XCTestCase {

    /// Malformed tool-call markup must NOT terminate the run: the coordinator
    /// retries with a correction instead of treating the response as a valid
    /// answer (previously broke the agentic loop mid-task).
    func testMalformedToolCallMarkupTriggersRetry() async throws {
        let mock = MalformedThenValidMockService()
        let coordinator = AIInteractionCoordinator(
            aiService: mock,
            eventBus: EventBus()
        )

        let result = await coordinator.sendMessageWithRetry(
            .init(
                messages: [ChatMessage(role: .user, content: "write the file")],
                tools: [TestNoopTool(name: "write", description: "Write")],
                mode: .coder,
                projectRoot: FileManager.default.temporaryDirectory,
                runId: "test-run",
                stage: .tool_loop,
                conversationId: "conv-1"
            )
        )

        let response = try result.get()
        XCTAssertGreaterThanOrEqual(mock.callCount, 2, "Malformed markup must trigger at least one retry")
        XCTAssertEqual(response.toolCalls?.first?.name, "write", "The retried call must be recovered")
    }

    /// Valid tool calls pass through without retry.
    func testValidToolCallsDoNotRetry() async throws {
        let mock = AlwaysValidMockService()
        let coordinator = AIInteractionCoordinator(
            aiService: mock,
            eventBus: EventBus()
        )

        let result = await coordinator.sendMessageWithRetry(
            .init(
                messages: [ChatMessage(role: .user, content: "read a file")],
                tools: [TestNoopTool(name: "read", description: "Read")],
                mode: .coder,
                projectRoot: FileManager.default.temporaryDirectory,
                runId: "test-run",
                stage: .tool_loop,
                conversationId: "conv-1"
            )
        )

        _ = try result.get()
        XCTAssertEqual(mock.callCount, 1, "A valid tool-call response must not retry")
    }
}

private struct TestNoopTool: AITool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: [String: Any] = ["type": "object"]
    func execute(arguments: ToolArguments) async throws -> String { "ok" }
}

/// Always returns a valid structured tool call — used to prove the valid
/// path does not retry.
private final class AlwaysValidMockService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        validNext()
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        validNext()
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        validNext()
    }

    private func validNext() -> AIServiceResponse {
        lock.lock()
        calls += 1
        lock.unlock()
        let call = AIToolCall(id: "call_ok", name: "write", arguments: ["path": "a.txt", "content": "hello"])
        return AIServiceResponse(content: "", toolCalls: [call])
    }
}

/// First call returns raw Gemma-style tool markup with NO recoverable calls;
/// subsequent calls return a valid structured call.
private final class MalformedThenValidMockService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        print("[MOCK-METHOD] projectRoot-request")
        return next()
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        print("[MOCK-METHOD] history-request")
        return next()
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        print("[MOCK-METHOD] streaming")
        return next()
    }

    private func next() -> AIServiceResponse {
        lock.lock()
        calls += 1
        let attempt = calls
        lock.unlock()
        print("[MOCK-CALL] attempt \(attempt)")
        if attempt == 1 {
            return AIServiceResponse(
                content: "<|tool_call>call:write{content:<|\"|>hello<|\"|>,path:<|\"|>a.txt<|\"|>}",
                toolCalls: nil
            )
        }
        let call = AIToolCall(id: "call_ok", name: "write", arguments: ["path": "a.txt", "content": "hello"])
        return AIServiceResponse(content: "", toolCalls: [call])
    }
}
