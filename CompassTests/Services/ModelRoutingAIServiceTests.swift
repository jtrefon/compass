import XCTest
@testable import Compass

@MainActor
final class ModelRoutingAIServiceTests: XCTestCase {
    private final class SpyAIService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
        var sendMessageWithProjectRootCallCount = 0
        var sendHistoryCallCount = 0
        var sendStreamingCallCount = 0
        var lastMessageRequest: AIServiceMessageWithProjectRootRequest?
        var lastHistoryRequest: AIServiceHistoryRequest?
        var streamingResponse = AIServiceResponse(content: "streaming", toolCalls: nil)
        var response = AIServiceResponse(content: "ok", toolCalls: nil)

        func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
            sendMessageWithProjectRootCallCount += 1
            lastMessageRequest = request
            return response
        }

        func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
            sendHistoryCallCount += 1
            lastHistoryRequest = request
            return response
        }

        func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
            _ = runId
            sendStreamingCallCount += 1
            lastHistoryRequest = request
            return streamingResponse
        }
    }

    private var defaultsSuiteName: String!
    private var settingsStore: SettingsStore!
    private var selectionStore: LocalModelSelectionStore!
    private var providerSelectionStore: AIProviderSelectionStore!
    private var registry: AIServiceRegistry!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "ModelRoutingAIServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        settingsStore = SettingsStore(userDefaults: defaults)
        selectionStore = LocalModelSelectionStore(settingsStore: settingsStore)
        providerSelectionStore = AIProviderSelectionStore(settingsStore: settingsStore)
        registry = AIServiceRegistry(
            providerSelectionStore: providerSelectionStore,
            localSelectionStore: selectionStore
        )
    }

    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        }
        registry = nil
        selectionStore = nil
        providerSelectionStore = nil
        settingsStore = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testOfflineAgentHistoryRequestRoutesToLocalService() async throws {
        let openRouterService = SpyAIService()
        let localService = SpyAIService()
        registry.register(provider: .openRouter, service: openRouterService)
        registry.register(provider: .local, service: localService)
        await selectionStore.setOfflineModeEnabled(true)
        await providerSelectionStore.setSelectedRemoteProvider(.openRouter)

        let service = ModelRoutingAIService(registry: registry)

        let response = try await service.sendMessage(AIServiceHistoryRequest(
            messages: [ChatMessage(role: .user, content: "Create file")],
            context: nil,
            tools: nil,
            mode: .agent,
            projectRoot: nil,
            runId: "run-1",
            stage: .tool_loop,
            conversationId: "conversation-1"
        ))

        XCTAssertEqual(response.content, "ok")
        XCTAssertEqual(localService.sendHistoryCallCount, 1)
        XCTAssertEqual(openRouterService.sendHistoryCallCount, 0)
        XCTAssertEqual(localService.lastHistoryRequest?.mode, .agent)
        XCTAssertEqual(localService.lastHistoryRequest?.stage, .tool_loop)
        XCTAssertEqual(localService.lastHistoryRequest?.conversationId, "conversation-1")
    }

    func testOfflineAgentStreamingRequestRoutesToLocalService() async throws {
        let openRouterService = SpyAIService()
        let localService = SpyAIService()
        localService.streamingResponse = AIServiceResponse(content: "local-stream", toolCalls: nil)
        registry.register(provider: .openRouter, service: openRouterService)
        registry.register(provider: .local, service: localService)
        await selectionStore.setOfflineModeEnabled(true)
        await providerSelectionStore.setSelectedRemoteProvider(.openRouter)

        let service = ModelRoutingAIService(registry: registry)

        let response = try await service.sendMessageStreaming(AIServiceHistoryRequest(
            messages: [ChatMessage(role: .user, content: "Do work")],
            context: nil,
            tools: nil,
            mode: .agent,
            projectRoot: nil,
            runId: "run-2",
            stage: .initial_response,
            conversationId: "conversation-2"
        ), runId: "run-2")

        XCTAssertEqual(response.content, "local-stream")
        XCTAssertEqual(localService.sendStreamingCallCount, 1)
        XCTAssertEqual(openRouterService.sendStreamingCallCount, 0)
        XCTAssertEqual(localService.lastHistoryRequest?.mode, .agent)
    }

    func testOnlineAgentHistoryRequestRoutesToOpenRouter() async throws {
        let openRouterService = SpyAIService()
        let localService = SpyAIService()
        registry.register(provider: .openRouter, service: openRouterService)
        registry.register(provider: .local, service: localService)
        await selectionStore.setOfflineModeEnabled(false)
        await providerSelectionStore.setSelectedRemoteProvider(.openRouter)

        let service = ModelRoutingAIService(registry: registry)

        let response = try await service.sendMessage(AIServiceHistoryRequest(
            messages: [ChatMessage(role: .user, content: "Create file")],
            context: nil,
            tools: nil,
            mode: .agent,
            projectRoot: nil
        ))

        XCTAssertEqual(response.content, "ok")
        XCTAssertEqual(openRouterService.sendHistoryCallCount, 1)
        XCTAssertEqual(localService.sendHistoryCallCount, 0)
        XCTAssertEqual(openRouterService.lastHistoryRequest?.mode, .agent)
    }

    func testOnlineAgentHistoryRequestRoutesToAlibabaWhenSelected() async throws {
        let openRouterService = SpyAIService()
        let alibabaService = SpyAIService()
        let localService = SpyAIService()
        registry.register(provider: .openRouter, service: openRouterService)
        registry.register(provider: .alibabaCloud, service: alibabaService)
        registry.register(provider: .local, service: localService)
        await selectionStore.setOfflineModeEnabled(false)
        await providerSelectionStore.setSelectedRemoteProvider(.alibabaCloud)

        let service = ModelRoutingAIService(registry: registry)

        let response = try await service.sendMessage(AIServiceHistoryRequest(
            messages: [ChatMessage(role: .user, content: "Create file")],
            context: nil,
            tools: nil,
            mode: .agent,
            projectRoot: nil
        ))

        XCTAssertEqual(response.content, "ok")
        XCTAssertEqual(alibabaService.sendHistoryCallCount, 1)
        XCTAssertEqual(openRouterService.sendHistoryCallCount, 0)
        XCTAssertEqual(alibabaService.lastHistoryRequest?.mode, .agent)
    }
}
