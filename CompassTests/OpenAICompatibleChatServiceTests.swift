import XCTest
import Combine
@testable import Compass

final class OpenAICompatibleChatServiceTests: XCTestCase {
    private var eventBus: EventBus!
    private var urlSession: URLSession!
    private var config: OpenRouterProviderConfig!
    private var usageTracker: UsageTracker!
    private var service: OpenAICompatibleChatService!

    override func setUp() {
        eventBus = EventBus()
        config = OpenRouterProviderConfig()
        let urlConfig = URLProtocolMock.makeProtocolConfiguration()
        urlSession = URLSession(configuration: urlConfig)
        let client = OpenRouterAPIClient(urlSession: urlSession)
        usageTracker = UsageTracker(client: client, eventBus: eventBus)
        service = OpenAICompatibleChatService(
            client: client,
            config: config,
            usageTracker: usageTracker,
            eventBus: eventBus,
            testConfigurationProvider: TestConfigurationProvider(),
            parserRegistry: ParserRegistry.default(),
            supportsStreamingWithToolsOverride: true,
            settingsStoreProvider: { FixedTestSettingsStore() }
        )
    }

    override func tearDown() {
        URLProtocolMock.requestHandler = nil
        service = nil
        usageTracker = nil
        config = nil
        urlSession = nil
        eventBus = nil
    }

    func testProviderNameMatchesConfig() {
        func makeService(config: any ProviderConfig) -> OpenAICompatibleChatService {
            let c = OpenRouterAPIClient(urlSession: urlSession)
            let u = UsageTracker(client: c, eventBus: eventBus!)
            return OpenAICompatibleChatService(client: c, config: config, usageTracker: u, eventBus: eventBus!)
        }

        XCTAssertEqual(makeService(config: OpenRouterProviderConfig()).providerName, "OpenRouter")
        XCTAssertEqual(makeService(config: DeepSeekProviderConfig()).providerName, "DeepSeek")
        XCTAssertEqual(makeService(config: KiloCodeProviderConfig()).providerName, "Kilo Code")
        XCTAssertEqual(makeService(config: OpenCodeGoProviderConfig()).providerName, "OpenCode Go")
        XCTAssertEqual(makeService(config: OpenCodeGoSubscriptionProviderConfig()).providerName, "OpenCode Go (Subscription)")
        XCTAssertEqual(makeService(config: AlibabaProviderConfig()).providerName, "Alibaba Cloud")
    }

    func testSendMessageUsesCorrectRequestBody() async throws {
        let expectation = XCTestExpectation(description: "Request captured")
        URLProtocolMock.requestHandler = { request in
            expectation.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"id":"test","object":"chat.completion","created":123,"model":"test","choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
            """.data(using: .utf8)!
            return (response, data)
        }

        let response = try await service.sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Hi", context: nil, tools: nil, mode: nil, projectRoot: nil
        ))

        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(response.content, "Hello")
    }

    func testSendMessageWithToolCalls() async throws {
        URLProtocolMock.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Tool calls format is tested separately; verify request body has tools
            let data = """
            {"id":"test","object":"chat.completion","created":123,"model":"test","choices":[{"index":0,"message":{"role":"assistant","content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
            """.data(using: .utf8)!
            return (response, data)
        }

        let tool = OpenAITestNoopTool(name: "write_file", description: "Write a file", parameters: [
            "type": "object",
            "properties": ["path": ["type": "string"]],
            "required": ["path"]
        ])

        // Test that the request includes tool definitions correctly
        let response = try await service.sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Write hello.txt",
            context: nil,
            tools: [tool],
            mode: .agent,
            projectRoot: nil
        ))

        XCTAssertEqual(response.content, "Done")
    }

    func testSendMessageThrowsOnEmptyChoices() async {
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"id":"test","object":"chat.completion","created":123,"model":"test","choices":[],"usage":null}
            """.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await service.sendMessage(AIServiceMessageWithProjectRootRequest(
                message: "Hi", context: nil, tools: nil, mode: nil, projectRoot: nil
            ))
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    func testSendMessageStreamingWithMockData() async throws {
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            let chunks = [
                "data: {\"id\":\"test\",\"object\":\"chat.completion.chunk\",\"created\":123,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n",
                "data: {\"id\":\"test\",\"object\":\"chat.completion.chunk\",\"created\":123,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"},\"finish_reason\":\"stop\"}]}\n",
                "data: [DONE]\n"
            ]
            let data = chunks.joined().data(using: .utf8)!
            return (response, data)
        }

        let response = try await service.sendMessageStreaming(
            AIServiceHistoryRequest(
                messages: [ChatMessage(role: .user, content: "Say hi")],
                context: nil, tools: nil, mode: nil, projectRoot: nil, runId: "test-run"
            ),
            runId: "test-run"
        )

        XCTAssertEqual(response.content, "Hello world")
    }
    // MARK: - Blind-loop regression (tool results must survive into requests)

    /// A committed assistant message carrying toolCalls must keep its tool
    /// results in the next request (the graph now commits the assistant
    /// tool-call message before appending results).
    func testToolResultsSurviveWhenAssistantToolCallMessageIsCommitted() async throws {
        let call = AIToolCall(id: "call_1", name: "read", arguments: ["path": "a.swift"])
        let assistantToolCall = ChatMessage(
            role: .assistant,
            content: "",
            tool: ChatMessageToolContext(toolCalls: [call])
        )
        let toolResult = ChatMessage(
            role: .tool,
            content: "func main() {}",
            tool: ChatMessageToolContext(
                toolName: "read",
                toolStatus: .completed,
                target: ToolInvocationTarget(toolCallId: "call_1")
            )
        )
        let history: [ChatMessage] = [
            ChatMessage(role: .user, content: "read a.swift"),
            assistantToolCall,
            toolResult,
        ]

        URLProtocolMock.requestHandler = { request in
            // URLSession hands URLProtocol the body as httpBodyStream, not httpBody.
            let bodyData: Data
            if let body = request.httpBody {
                bodyData = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                bodyData = data
            } else {
                bodyData = Data()
            }
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            // The handler also sees side-channel requests (GET /models balance
            // refresh) — only the chat POST carries a body to assert on.
            if request.httpMethod == "POST", request.url?.path.hasSuffix("chat/completions") == true {
                XCTAssertTrue(body.contains("func main() {}"), "Tool result must be present in the request body")
                XCTAssertTrue(body.contains("call_1"), "Tool call id must be present")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"id":"t","object":"chat.completion","created":1,"model":"test","choices":[{"index":0,"message":{"role":"assistant","content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
            """.data(using: .utf8)!
            return (response, data)
        }

        _ = try await service.sendMessage(AIServiceHistoryRequest(
            messages: history,

            tools: [OpenAITestNoopTool(name: "read", description: "Read", parameters: ["type": "object"])],
            mode: .coder,
            projectRoot: nil
        ))
    }

}

// MARK: - URL Protocol Mock

private class URLProtocolMock: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolMock.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeProtocolConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return config
    }
}

/// Hermetic settings: the default store reads the host's real UserDefaults —
/// tests must not depend on the machine's live configuration.
private struct FixedTestSettingsStore: OpenRouterSettingsLoading {
    func load(includeApiKey: Bool) -> OpenRouterSettings {
        OpenRouterSettings(
            apiKey: includeApiKey ? "sk-test-key" : "",
            model: "test-model",
            baseURL: "https://openrouter.ai/api/v1",
            systemPrompt: "",
            reasoningMode: .none,
            toolPromptMode: .fullStatic,
            contextOverride: 0
        )
    }
}

private struct OpenAITestNoopTool: AITool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: [String: Any]
    func execute(arguments: ToolArguments) async throws -> String { "ok" }

}