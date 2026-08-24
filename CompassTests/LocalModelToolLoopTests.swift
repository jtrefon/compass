import XCTest
@testable import Compass

// MARK: - Test Doubles

/// In-memory mock for `ConversationHistoryProviding`.
/// Allows tests to inspect all appended messages without touching real state.
@MainActor
final class InMemoryConversationHistory: ConversationHistoryProviding {
    private(set) var messages: [ChatMessage] = []
    private var draft: ChatMessage?
    private var liveToolMessages: [String: ChatMessage] = [:]

    var requestMessages: [ChatMessage] { messages }

    func append(_ message: ChatMessage) async {
        messages.append(message)
    }

    func appendSync(_ message: ChatMessage) {
        messages.append(message)
    }

    func setDraft(_ message: ChatMessage) {
        draft = message
    }

    func clearDraft() {
        draft = nil
    }

    func setLiveToolMessage(_ message: ChatMessage) {
        guard let id = message.toolCallId else { return }
        liveToolMessages[id] = message
    }

    func clearLiveToolMessage(_ toolCallId: String) {
        liveToolMessages.removeValue(forKey: toolCallId)
    }

    // MARK: - Test helpers

    func reset() {
        messages = []
        draft = nil
        liveToolMessages = [:]
    }
}

// MARK: - LocalModelToolLoopLogger Tests

@MainActor
final class LocalModelToolLoopLoggerTests: XCTestCase {
    func testLoggerInitializesWithoutError() {
        let logger = LocalModelToolLoopLogger()
        XCTAssertNotNil(logger)
    }
}

// MARK: - LocalModelIterationGuide Tests

@MainActor
final class LocalModelIterationGuideTests: XCTestCase {
    let guide = LocalModelIterationGuide()

    func testNoRepetitionWithoutPreviousCalls() {
        let call = AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"])
        let result = guide.detectRepetition(current: call, previousToolCalls: [])
        XCTAssertNil(result)
    }

    func testIdenticalCallDetected() {
        let previous = AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"])
        let current = AIToolCall(id: "2", name: "bash", arguments: ["command": "ls"])
        let result = guide.detectRepetition(current: current, previousToolCalls: [previous])
        XCTAssertNotNil(result)
        if case .identicalCall(let name, _) = result {
            XCTAssertEqual(name, "bash")
        } else {
            XCTFail("Expected .identicalCall")
        }
    }

    func testDifferentArgumentsNoRepetition() {
        let previous = AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"])
        let current = AIToolCall(id: "2", name: "bash", arguments: ["command": "cat file.txt"])
        let result = guide.detectRepetition(current: current, previousToolCalls: [previous])
        XCTAssertNil(result)
    }

    func testDifferentToolNoRepetition() {
        let previous = AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"])
        let current = AIToolCall(id: "2", name: "read", arguments: ["path": "file.txt"])
        let result = guide.detectRepetition(current: current, previousToolCalls: [previous])
        XCTAssertNil(result)
    }

    func testCorrectiveMessageContainsToolName() {
        let repetition: LocalModelIterationGuide.RepetitionKind = .identicalCall(
            name: "bash", arguments: ["command": "ls"]
        )
        let message = guide.correctiveMessage(for: repetition, iteration: 2)
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("bash"))
    }

    func testContinueGuidanceContainsToolName() {
        let call = AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"])
        let msg = ChatMessage(role: .tool, content: "file1.txt", tool: ChatMessageToolContext(
            toolName: "bash", toolStatus: .completed,
            target: ToolInvocationTarget(toolCallId: "1")
        ))
        let message = guide.continueGuidance(toolCalls: [call], toolResults: [msg], iteration: 1)
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("bash"))
    }

    func testFinalizeMessageContainsCounts() {
        let message = guide.finalizeMessage(completedIterations: 5, totalToolCalls: 12)
        XCTAssertTrue(message.contains("5"))
        XCTAssertTrue(message.contains("12"))
    }

    // MARK: - Batch repetition detection

    func testBatchRepetitionDetectsIdenticalBatches() {
        let previous = [
            AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"]),
            AIToolCall(id: "2", name: "read", arguments: ["path": "a.swift"]),
        ]
        let current = [
            AIToolCall(id: "3", name: "bash", arguments: ["command": "ls"]),
            AIToolCall(id: "4", name: "read", arguments: ["path": "a.swift"]),
        ]
        let result = guide.detectBatchRepetition(current: current, previous: previous)
        XCTAssertNotNil(result)
    }

    /// Regression: comparing only first-vs-last misses a repeated call inside
    /// a grown batch (`[read:a]` → `[read:a, read:b]`). Full-batch signature
    /// comparison must NOT flag it as identical (it isn't one), but the
    /// single-call repeat case still must be.
    func testGrownBatchWithRepeatedPrefixIsNotIdentical() {
        let previous = [AIToolCall(id: "1", name: "read", arguments: ["path": "a"])]
        let current = [
            AIToolCall(id: "2", name: "read", arguments: ["path": "a"]),
            AIToolCall(id: "3", name: "read", arguments: ["path": "b"]),
        ]
        XCTAssertNil(guide.detectBatchRepetition(current: current, previous: previous))
    }

    func testBatchOrderInsensitivity() {
        let previous = [
            AIToolCall(id: "1", name: "bash", arguments: ["command": "ls"]),
            AIToolCall(id: "2", name: "read", arguments: ["path": "a"]),
        ]
        let current = [
            AIToolCall(id: "3", name: "read", arguments: ["path": "a"]),
            AIToolCall(id: "4", name: "bash", arguments: ["command": "ls"]),
        ]
        XCTAssertNotNil(guide.detectBatchRepetition(current: current, previous: previous))
    }

    func testBatchWithDifferentArgumentsIsNotRepetition() {
        let previous = [AIToolCall(id: "1", name: "read", arguments: ["path": "a"])]
        let current = [AIToolCall(id: "2", name: "read", arguments: ["path": "b"])]
        XCTAssertNil(guide.detectBatchRepetition(current: current, previous: previous))
    }

    func testBatchDetectionWithoutPreviousReturnsNil() {
        let current = [AIToolCall(id: "1", name: "read", arguments: ["path": "a"])]
        XCTAssertNil(guide.detectBatchRepetition(current: current, previous: []))
    }
}

// MARK: - LocalModelToolLoop Configuration Tests

@MainActor
final class LocalModelToolLoopConfigurationTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = LocalModelToolLoop.Configuration.default(
            mode: .coder,
            projectRoot: URL(fileURLWithPath: "/tmp"),
            conversationId: "test",
            runId: "run-1"
        )
        XCTAssertEqual(config.maxIterations, 8)
        XCTAssertEqual(config.mode, .coder)
    }
}

// MARK: - InMemoryConversationHistory Tests

@MainActor
final class InMemoryConversationHistoryTests: XCTestCase {
    func testAppendAddsMessage() async {
        let history = InMemoryConversationHistory()
        let msg = ChatMessage(role: .user, content: "hello")
        await history.append(msg)
        XCTAssertEqual(history.messages.count, 1)
        XCTAssertEqual(history.requestMessages.count, 1)
    }

    func testAppendSyncAddsMessage() {
        let history = InMemoryConversationHistory()
        let msg = ChatMessage(role: .user, content: "hello")
        history.appendSync(msg)
        XCTAssertEqual(history.messages.count, 1)
    }

    func testResetClearsAll() async {
        let history = InMemoryConversationHistory()
        await history.append(ChatMessage(role: .user, content: "hello"))
        history.setDraft(ChatMessage(role: .assistant, content: "draft"))
        history.reset()
        XCTAssertEqual(history.messages.count, 0)
        XCTAssertTrue(history.requestMessages.isEmpty)
    }

    func testSetDraftAndClear() {
        let history = InMemoryConversationHistory()
        let draft = ChatMessage(role: .assistant, content: "draft")
        history.setDraft(draft)
        history.clearDraft()
        XCTAssertNoThrow(history.clearDraft())
    }

    func testLiveToolMessage() {
        let history = InMemoryConversationHistory()
        let msg = ChatMessage(role: .tool, content: "result", tool: ChatMessageToolContext(
            toolName: "bash", toolStatus: .executing,
            target: ToolInvocationTarget(toolCallId: "call-1")
        ))
        history.setLiveToolMessage(msg)
        history.clearLiveToolMessage("call-1")
        XCTAssertNoThrow(history.clearLiveToolMessage("nonexistent"))
    }
}
