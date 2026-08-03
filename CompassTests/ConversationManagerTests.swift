//
//  ConversationManagerTests.swift
//  CompassTests
//
//  Created by Jack Trefon on 21/12/2025.
//

import XCTest
import Combine
@testable import Compass

@MainActor
final class ConversationManagerTests: XCTestCase {

    var manager: ConversationManager!
    var mockAIService: MockAIService!
    var mockErrorManager: MockErrorManager!
    var mockActivityCoordinator: AgentActivityCoordinator!
    var eventBus: EventBus!
    let historyKey = "AIChatHistory"

    override func setUp() async throws {
        try await super.setUp()
        // SessionManager + SettingsStore persist to the launch context's
        // defaults — which is the isolated test suite under the test runner
        // (AppRuntimeEnvironment.userDefaults) — clear every key they touch so
        // tests are isolated from each other and from prior runs.
        let defaults = AppRuntimeEnvironment.userDefaults
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: "SessionManager.sessionOrder")
        defaults.removeObject(forKey: "SessionManager.selectedId")
        defaults.removeObject(forKey: "SessionManager.closedRegistry")
        mockAIService = MockAIService()
        mockErrorManager = MockErrorManager()
        mockActivityCoordinator = AgentActivityCoordinator(powerManagementService: MockPowerManagementService())
        eventBus = EventBus()
        let fileSystemService = FileSystemService()
        let workspaceService = WorkspaceService(
            errorManager: mockErrorManager,
            eventBus: eventBus,
            fileSystemService: fileSystemService
        )
        manager = ConversationManager(
            dependencies: ConversationManager.Dependencies(
                services: ConversationManager.ServiceDependencies(
                    aiService: mockAIService,
                    errorManager: mockErrorManager,
                    fileSystemService: fileSystemService,
                    fileEditorService: nil,
                    activityCoordinator: mockActivityCoordinator
                ),
                environment: ConversationManager.EnvironmentDependencies(
                    workspaceService: workspaceService,
                    eventBus: eventBus,
                    projectRoot: URL(fileURLWithPath: "/tmp"),
                    codebaseIndex: nil
                )
            )
        )
    }

    override func tearDown() async throws {
        let defaults = AppRuntimeEnvironment.userDefaults
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: "SessionManager.sessionOrder")
        defaults.removeObject(forKey: "SessionManager.selectedId")
        defaults.removeObject(forKey: "SessionManager.closedRegistry")
        manager = nil
        mockAIService = nil
        mockErrorManager = nil
        eventBus = nil
        try await super.tearDown()
    }

    func testWelcomeMessage() {
        // Coordinator starts empty; welcome message is handled by the UI layer
        XCTAssertEqual(manager.messages.count, 0, "Expected empty conversation on init")
    }

    func testSendMessageFlow() async throws {
        manager.currentInput = "Hello AI"

        let aiResponded = expectation(description: "AI responded")
        aiResponded.assertForOverFulfill = false

        // Observe manager's objectWillChange to wait for response
        var cancellables = Set<AnyCancellable>()
        manager.objectWillChange
            .sink { _ in
                // Using a small delay to allow state to actually change after notification
                Task { @MainActor in
                    if self.manager.messages.contains(where: {
                        $0.role == MessageRole.assistant && $0.content == "Mock response"
                    }) {
                        aiResponded.fulfill()
                    }
                }
            }
            .store(in: &cancellables)

        manager.sendMessage()

        await fulfillment(of: [aiResponded], timeout: 5.0)

        let sendingCleared = self.expectation(description: "Sending cleared")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if self.manager.isSending == false {
                    sendingCleared.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await fulfillment(of: [sendingCleared], timeout: 3.0)
        XCTAssertFalse(manager.isSending)
    }

    /// Regression guard for the chat panel send path:
    /// verifies an agent-mode input reaches AI service and produces an assistant response.
    func testAgentModeSendMessageRequestResponse() async throws {
        mockAIService.nextHistoryResponse = AIServiceResponse(content: "Agent response", toolCalls: nil)
        manager.currentMode = .agent
        manager.currentInput = "Run in agent mode"

        let agentResponded = expectation(description: "Agent responded")
        agentResponded.assertForOverFulfill = false

        var cancellables = Set<AnyCancellable>()
        manager.objectWillChange
            .sink { _ in
                Task { @MainActor in
                    if self.manager.messages.contains(where: {
                        $0.role == MessageRole.assistant && $0.content == "Agent response"
                    }) {
                        agentResponded.fulfill()
                    }
                }
            }
            .store(in: &cancellables)

        manager.sendMessage()

        await fulfillment(of: [agentResponded], timeout: 5.0)

        let sendingCleared = expectation(description: "Agent sending cleared")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if self.manager.isSending == false {
                    sendingCleared.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await fulfillment(of: [sendingCleared], timeout: 3.0)

        XCTAssertEqual(mockAIService.lastHistoryRequest?.mode, .agent)
        XCTAssertFalse(manager.isSending)
    }

    func testLiveModelOutputPreviewVisibleByDefault() {
        XCTAssertTrue(manager.isLiveModelOutputPreviewVisible)
    }

    func testSendMessageUpdatesLiveModelOutputPreviewWithFinalAssistantResponse() async throws {
        mockAIService.nextHistoryResponse = AIServiceResponse(content: "Preview-ready assistant response", toolCalls: nil)
        manager.currentInput = "Show me output"

        manager.sendMessage()

        let responseExpectation = expectation(description: "Preview updated")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                let finalAssistantMessage = self.manager.messages.last(where: { $0.role == .assistant && !$0.isDraft })
                if self.manager.isSending == false,
                   let finalAssistantMessage,
                   !finalAssistantMessage.content.isEmpty,
                   self.manager.liveModelOutputPreview == finalAssistantMessage.content {
                    responseExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        await fulfillment(of: [responseExpectation], timeout: 3.0)
        let finalAssistantMessage = manager.messages.last(where: { $0.role == .assistant && !$0.isDraft })
        XCTAssertEqual(manager.liveModelOutputPreview, finalAssistantMessage?.content)
    }

    func testSplitReasoningExtractsAndStripsBlock() {
        let input = """
        Reflection: A
        Planning: B
        Continuity: D

        Hello world.
        """

        let result = ChatPromptBuilder.splitReasoning(from: input)
        XCTAssertEqual(result.content, "Hello world.")
        XCTAssertNotNil(result.reasoning)
        XCTAssertTrue((result.reasoning ?? "").contains("Reflection:"))
        XCTAssertTrue((result.reasoning ?? "").contains("Continuity:"))
    }

    func testClearConversationResetsInteractionState() async {
        manager.currentInput = "Work in progress"
        manager.sendMessage()

        // Ensure we hit active sending state before clear
        let sendingExpectation = expectation(description: "Manager entered sending state")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if self.manager.isSending {
                    sendingExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [sendingExpectation], timeout: 2.0)

        manager.clearConversation()

        XCTAssertFalse(manager.isSending)
        XCTAssertEqual(manager.currentInput, "")
        XCTAssertEqual(
            manager.messages.count, 0,
            "Expected empty messages after clear"
        )
    }

    func testStopGenerationCancelsInFlightResponse() async {
        mockAIService.responseDelayNanoseconds = 800_000_000
        manager.currentInput = "Long running task"
        manager.sendMessage()

        let sendingExpectation = expectation(description: "Manager entered sending state")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if self.manager.isSending {
                    sendingExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [sendingExpectation], timeout: 2.0)

        manager.stopGeneration()

        XCTAssertFalse(manager.isSending)
        XCTAssertEqual(manager.liveModelOutputPreview, "Generation stopped by user.")
    }

    func testProviderIssueEventUpdatesConversationState() {
        let cooldownUntil = Date().addingTimeInterval(45)

        eventBus.publish(ProviderIssueStatusEvent(
            providerName: "OpenRouter",
            statusKind: .rateLimited,
            statusCode: 429,
            message: "Provider rate limit hit. Retrying when cooldown ends.",
            cooldownUntil: cooldownUntil
        ))

        let expectation = expectation(description: "Provider issue propagated")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if self.manager.providerIssue?.providerName == "OpenRouter" {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(manager.providerIssue?.providerName, "OpenRouter")
        XCTAssertEqual(manager.providerIssue?.issueType, "Rate limit")
        XCTAssertEqual(manager.providerIssue?.statusCode, 429)
        XCTAssertEqual(manager.providerIssue?.message, "Provider rate limit hit. Retrying when cooldown ends.")
        XCTAssertEqual(manager.providerIssue?.cooldownUntil, cooldownUntil)
    }

    func testSendMessageClearsPreviousProviderIssueState() {
        eventBus.publish(ProviderIssueStatusEvent(
            providerName: "OpenRouter",
            statusKind: .unavailable,
            statusCode: 503,
            message: "Provider unavailable.",
            cooldownUntil: nil
        ))

        let publishedExpectation = expectation(description: "Provider issue published")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if self.manager.providerIssue != nil {
                    publishedExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        wait(for: [publishedExpectation], timeout: 2.0)
        XCTAssertNotNil(manager.providerIssue)

        manager.currentInput = "Hello again"
        manager.sendMessage()

        XCTAssertNil(manager.providerIssue)
    }

    func testSuccessfulSendClearsProviderIssuePublishedMidRequest() async throws {
        mockAIService.nextHistoryResponse = AIServiceResponse(content: "Recovered response", toolCalls: nil)
        mockAIService.responseDelayNanoseconds = 100_000_000
        mockAIService.onSendHistoryRequest = { [eventBus] _ in
            eventBus?.publish(ProviderIssueStatusEvent(
                providerName: "OpenRouter",
                statusKind: .rateLimited,
                statusCode: 429,
                message: "Provider cooldown active. Waiting before the next request.",
                cooldownUntil: Date().addingTimeInterval(30)
            ))
        }

        manager.currentInput = "Retry this"
        manager.sendMessage()

        let completionExpectation = expectation(description: "Send completed and provider issue cleared")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                let finalAssistantMessage = self.manager.messages.last(where: { $0.role == .assistant && !$0.isDraft })
                if self.manager.isSending == false,
                   finalAssistantMessage?.content == "Recovered response",
                   self.manager.providerIssue == nil {
                    completionExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        await fulfillment(of: [completionExpectation], timeout: 3.0)
        XCTAssertNil(manager.providerIssue)
    }

    func testStartNewConversationCreatesNewTabAndSwitchesToIt() {
        let initialTabCount = manager.conversationTabs.count
        let initialConversationId = manager.currentConversationId

        manager.startNewConversation()

        XCTAssertEqual(manager.conversationTabs.count, initialTabCount + 1)
        XCTAssertNotEqual(manager.currentConversationId, initialConversationId)
        XCTAssertEqual(manager.currentConversationId, manager.conversationTabs.last?.id)
    }

    func testSwitchConversationRestoresPerTabInputStateAndCloseRemovesSession() {
        manager.currentInput = "Session A draft"
        let firstSessionId = manager.currentConversationId

        manager.startNewConversation()
        let secondSessionId = manager.currentConversationId
        manager.currentInput = "Session B draft"

        manager.switchConversation(to: firstSessionId)
        XCTAssertEqual(manager.currentInput, "Session A draft")

        manager.switchConversation(to: secondSessionId)
        XCTAssertEqual(manager.currentInput, "Session B draft")

        manager.closeConversation(id: secondSessionId)
        XCTAssertEqual(manager.currentConversationId, firstSessionId)
        XCTAssertFalse(manager.conversationTabs.contains(where: { $0.id == secondSessionId }))
    }

    func testUpdateProjectRootRebindsToolExecutionToWorkspaceRoot() async throws {
        let bootstrapRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass-bootstrap-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bootstrapRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: bootstrapRoot)
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let eventBus = EventBus()
        let fileSystemService = FileSystemService()
        let workspaceService = WorkspaceService(
            errorManager: mockErrorManager,
            eventBus: eventBus,
            fileSystemService: fileSystemService
        )
        let agentManager = ConversationManager(
            dependencies: ConversationManager.Dependencies(
                services: ConversationManager.ServiceDependencies(
                    aiService: mockAIService,
                    errorManager: mockErrorManager,
                    fileSystemService: fileSystemService,
                    fileEditorService: nil,
                    activityCoordinator: mockActivityCoordinator
                ),
                environment: ConversationManager.EnvironmentDependencies(
                    workspaceService: workspaceService,
                    eventBus: eventBus,
                    projectRoot: nil,
                    codebaseIndex: nil
                )
            )
        )

        agentManager.updateProjectRoot(workspaceRoot)
        agentManager.currentMode = .agent
        mockAIService.nextHistoryResponse = AIServiceResponse(
            content: nil,
            toolCalls: [AIToolCall(id: "call-root-fix", name: "write_file", arguments: [
                "path": "created-from-agent.txt",
                "content": "root propagation works"
            ])]
        )
        agentManager.currentInput = "Create created-from-agent.txt"
        agentManager.sendMessage()

        let timeout = Date().addingTimeInterval(5)
        while agentManager.isSending, Date() < timeout {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(agentManager.isSending)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspaceRoot.appendingPathComponent("created-from-agent.txt").path
            ),
            "Expected tool execution to target the updated workspace root"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bootstrapRoot.appendingPathComponent("created-from-agent.txt").path
            ),
            "Tool execution should not continue writing into the temporary bootstrap root"
        )
    }

    func testRecoverConversationLoadsMessagesIntoManager() {
        UserDefaults.standard.removeObject(forKey: "SessionManager.sessionOrder")
        UserDefaults.standard.removeObject(forKey: "SessionManager.selectedId")
        UserDefaults.standard.removeObject(forKey: "SessionManager.closedRegistry")

        let firstId = manager.currentConversationId
        manager.currentInput = "first session draft"
        manager.startNewConversation()
        let _ = manager.currentConversationId
        manager.closeConversation(id: firstId)

        XCTAssertTrue(manager.closedConversations.contains { $0.id == firstId },
                      "first session should be in closed list")

        manager.recoverConversation(id: firstId)

        XCTAssertEqual(manager.currentConversationId, firstId, "recovered session should become current")
    }

    func testRecoverConversationRestoresDisplayedMessages() async {
        UserDefaults.standard.removeObject(forKey: "SessionManager.sessionOrder")
        UserDefaults.standard.removeObject(forKey: "SessionManager.selectedId")
        UserDefaults.standard.removeObject(forKey: "SessionManager.closedRegistry")

        mockAIService.nextHistoryResponse = AIServiceResponse(content: "Recoverable answer", toolCalls: nil)
        manager.currentMode = .chat
        manager.currentInput = "remember me"
        let firstId = manager.currentConversationId

        let responded = expectation(description: "responded")
        responded.assertForOverFulfill = false
        var cancellables = Set<AnyCancellable>()
        manager.objectWillChange
            .sink { _ in
                Task { @MainActor in
                    if self.manager.messages.contains(where: { $0.role == .assistant && $0.content == "Recoverable answer" }) {
                        responded.fulfill()
                    }
                }
            }
            .store(in: &cancellables)
        manager.sendMessage()
        await fulfillment(of: [responded], timeout: 5.0)

        let messageCountBeforeClose = manager.messages.count
        XCTAssertGreaterThan(messageCountBeforeClose, 0)

        // Open a second session, then close the first.
        manager.startNewConversation()
        manager.closeConversation(id: firstId)
        XCTAssertTrue(manager.closedConversations.contains { $0.id == firstId })

        // Recover via the exact UI entry point.
        manager.recoverConversation(id: firstId)

        XCTAssertEqual(manager.currentConversationId, firstId)
        XCTAssertTrue(manager.messages.contains { $0.content == "Recoverable answer" },
                      "recovered messages were: \(manager.messages.map { $0.content })")
    }
    // MARK: - Agentic loop regression

    /// A conversational (no-tool) response must ADVANCE the graph, not re-loop
    /// the researcher — the old behavior re-sent identical context and the
    /// model repeated the same stub (observed 6x in production telemetry).
    func testConversationalResponseDoesNotLoopResearcher() async throws {
        mockAIService.nextHistoryResponse = AIServiceResponse(
            content: "I'd be happy to review one of your plugins! Which one?",
            toolCalls: nil
        )
        manager.currentMode = .coder

        let aiResponded = expectation(description: "AI responded")
        aiResponded.assertForOverFulfill = false
        var cancellables = Set<AnyCancellable>()
        manager.objectWillChange
            .sink { _ in
                Task { @MainActor in
                    if self.manager.messages.contains(where: {
                        $0.role == .assistant && $0.content.contains("happy to review")
                    }) {
                        aiResponded.fulfill()
                    }
                }
            }
            .store(in: &cancellables)

        manager.currentInput = "can you review one of my plugins?"
        manager.sendMessage()
        await fulfillment(of: [aiResponded], timeout: 10.0)

        XCTAssertLessThanOrEqual(mockAIService.sendCallCount, 3,
            "Conversational answer must advance (<=3 calls), not loop (was 8)")
        let assistantMsgs = manager.messages.filter { $0.role == .assistant && !$0.isDraft }
        XCTAssertEqual(assistantMsgs.count, 1, "Exactly one assistant message must be committed")
    }

    // MARK: - Answer replacement regression

    /// The FIRST conversational answer must be the committed one — a later
    /// divergent call (analyst re-asking) must NOT replace what the user
    /// saw stream (observed: researcher answer replaced by analyst text).
    func testFirstAnswerIsNotReplacedByLaterDivergentCall() async throws {
        mockAIService.queuedResponses = [
            AIServiceResponse(content: "Here is the review of career-register: solid architecture, missing capability checks.", toolCalls: nil),
            AIServiceResponse(content: "I certainly can. Please let me know which plugin...", toolCalls: nil),
        ]
        manager.currentMode = .coder

        let aiResponded = expectation(description: "AI responded")
        aiResponded.assertForOverFulfill = false
        var cancellables = Set<AnyCancellable>()
        manager.objectWillChange
            .sink { _ in
                Task { @MainActor in
                    if self.manager.messages.contains(where: {
                        $0.role == .assistant && !$0.isDraft && $0.content.contains("Here is the review")
                    }) {
                        aiResponded.fulfill()
                    }
                }
            }
            .store(in: &cancellables)

        manager.currentInput = "review career-register please"
        manager.sendMessage()
        await fulfillment(of: [aiResponded], timeout: 10.0)

        let committed = manager.messages.filter { $0.role == .assistant && !$0.isDraft }
        XCTAssertEqual(committed.count, 1)
        XCTAssertTrue(committed.first?.content.contains("Here is the review") == true,
            "Committed answer must be the FIRST one, not replaced: \(committed.first?.content.prefix(80) ?? "")")
    }

                }
// MARK: - Mocks

final class MockAIService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
    var nextHistoryResponse = AIServiceResponse(content: "Mock response", toolCalls: nil)
    var responseDelayNanoseconds: UInt64 = 0
    var onSendHistoryRequest: ((AIServiceHistoryRequest) -> Void)?
    private(set) var lastHistoryRequest: AIServiceHistoryRequest?
    /// Optional ordered responses consumed in sequence (falls back to
    /// `nextHistoryResponse`) — used to prove the committed answer is the
    /// FIRST one and is never replaced by a later divergent call.
    var queuedResponses: [AIServiceResponse] = []
    private let callLock = NSLock()
    private var calls = 0

    var sendCallCount: Int {
        callLock.lock()
        defer { callLock.unlock() }
        return calls
    }

    private func bumpCallCount() {
        callLock.lock()
        calls += 1
        callLock.unlock()
    }

    private func nextResponse() -> AIServiceResponse {
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        return nextHistoryResponse
    }

    func sendMessage(
        _ request: AIServiceMessageWithProjectRootRequest
    ) async throws -> AIServiceResponse {
        _ = request
        if responseDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: responseDelayNanoseconds)
        }
        return nextResponse()
    }

    func sendMessage(
        _ request: AIServiceHistoryRequest
    ) async throws -> AIServiceResponse {
        bumpCallCount()
        lastHistoryRequest = request
        onSendHistoryRequest?(request)
        if responseDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: responseDelayNanoseconds)
        }
        return nextResponse()
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        try await sendMessage(request)
    }
}

final class MockErrorManager: ObservableObject, ErrorManagerProtocol {
    @Published var currentError: AppError?
    @Published var showErrorAlert: Bool = false

    func handle(_ error: AppError) { self.currentError = error }
    func handle(_ error: Error, context: String) { }
    func dismissError() { self.showErrorAlert = false }

    var statePublisher: ObservableObjectPublisher {
        return self.objectWillChange
    }
}
