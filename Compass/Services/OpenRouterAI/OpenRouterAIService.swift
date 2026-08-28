import Foundation

actor OpenRouterAIService: AIService, RemoteAIAccountStatusRefreshing {
    private let inner: OpenAICompatibleChatService
    private let client: OpenRouterAPIClient
    private let settingsStore: any OpenRouterSettingsLoading
    private let _providerName: String
    private let usageTracker: UsageTracker

    nonisolated let providerName: String
    nonisolated let supportsStreamingWithTools: Bool
    nonisolated let supportsNativeReasoning: Bool
    nonisolated let preservesCache: Bool

    init(
        settingsStore: any OpenRouterSettingsLoading = OpenRouterSettingsStore(),
        client: OpenRouterAPIClient = OpenRouterAPIClient(),
        eventBus: EventBusProtocol,
        providerName: String = "OpenRouter",
        supportsStreamingWithTools: Bool = true,
        supportsNativeReasoning: Bool = true,
        testConfigurationProvider: TestConfigurationProvider = TestConfigurationProvider.shared
    ) {
        self.client = client
        self.settingsStore = settingsStore
        self._providerName = providerName
        self.providerName = providerName
        self.supportsStreamingWithTools = supportsStreamingWithTools
        self.supportsNativeReasoning = supportsNativeReasoning

        self.preservesCache = false

        let config: any ProviderConfig = OpenRouterAIService.resolveConfig(
            providerName: providerName,
            supportsStreamingWithTools: supportsStreamingWithTools,
            supportsNativeReasoning: supportsNativeReasoning
        )
        let rateLimiter = RateLimiter()
        let usageTracker = UsageTracker(client: client, eventBus: eventBus)
        self.usageTracker = usageTracker

        self.inner = OpenAICompatibleChatService(
            client: client,
            config: config,
            rateLimiter: rateLimiter,
            usageTracker: usageTracker,
            eventBus: eventBus,
            testConfigurationProvider: testConfigurationProvider,
            supportsStreamingWithToolsOverride: supportsStreamingWithTools,
            settingsStoreProvider: { [settingsStore] in settingsStore },
            preservesCache: false
        )
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        try await inner.sendMessage(request)
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        try await inner.sendMessage(request)
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        try await inner.sendMessageStreaming(request, runId: runId)
    }

    func refreshAccountBalance(runId: String?) async {
        let settings = settingsStore.load(includeApiKey: true)
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }
        await usageTracker.refreshAccountBalance(
            apiKey: apiKey,
            baseURL: settings.baseURL,
            providerName: _providerName,
            model: settings.model,
            runId: runId
        )
    }

    nonisolated static func extractFallbackToolCalls(from content: String) -> [AIToolCall]? {
        ParserRegistry.default().decodeToolCalls(from: content)
    }

    nonisolated static func decodeErrorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct ErrorBody: Decodable {
                struct Metadata: Decodable {
                    let raw: String?; let providerName: String?; let isByok: Bool?
                    enum CodingKeys: String, CodingKey { case raw; case providerName = "provider_name"; case isByok = "is_byok" }
                }
                let message: String?; let code: Int?; let metadata: Metadata?
            }
            let error: ErrorBody?
        }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let err = envelope.error else { return nil }
        let providerSuffix = err.metadata?.providerName.map { " Provider: \($0)." } ?? ""
        if let code = err.code, let message = err.message, !message.isEmpty { return "OpenRouter error (\(code)): \(message).\(providerSuffix)" }
        if let message = err.message, !message.isEmpty { return "OpenRouter error: \(message).\(providerSuffix)" }
        return nil
    }

    private static func resolveConfig(
        providerName: String,
        supportsStreamingWithTools: Bool,
        supportsNativeReasoning: Bool
    ) -> any ProviderConfig {
        switch providerName {
        case "Kilo Code": return KiloCodeProviderConfig()
        case "DeepSeek": return DeepSeekProviderConfig()
        case "Alibaba Cloud": return AlibabaProviderConfig()
        case "OpenCode Go": return OpenCodeGoProviderConfig()
        case "OpenCode Go (Subscription)": return OpenCodeGoSubscriptionProviderConfig()
        case "Custom Endpoint": return CustomEndpointProviderConfig()
        default: return OpenRouterProviderConfig()
        }
    }
}
