import Foundation

actor OpenAICompatibleChatService: AIService {
    private let client: OpenRouterAPIClient
    private let config: any ProviderConfig
    nonisolated let providerName: String
    nonisolated let preservesCache: Bool
    private let rateLimiter: RateLimiter
    private let usageTracker: UsageTracker
    private let eventBus: EventBusProtocol
    private let testConfigurationProvider: TestConfigurationProvider
    private let parserRegistry: ParserRegistry
    private let settingsStoreProvider: () -> any OpenRouterSettingsLoading
    /// Per-streaming-session running estimate, reset before each stream
    private var streamingPromptEstimate: Int = 0

    /// Accumulate token estimate from a streaming chunk (called on the actor)
    nonisolated let supportsStreamingWithToolsOverride: Bool

    init(
        client: OpenRouterAPIClient = OpenRouterAPIClient(),
        config: any ProviderConfig,
        rateLimiter: RateLimiter = RateLimiter(),
        usageTracker: UsageTracker,
        eventBus: EventBusProtocol,
        testConfigurationProvider: TestConfigurationProvider = TestConfigurationProvider.shared,
        parserRegistry: ParserRegistry = ParserRegistry.default(),
        supportsStreamingWithToolsOverride: Bool? = nil,
        settingsStoreProvider: @escaping () -> any OpenRouterSettingsLoading = { OpenRouterSettingsStore() },
        preservesCache: Bool = false
    ) {
        self.client = client
        self.config = config
        self.rateLimiter = rateLimiter
        self.usageTracker = usageTracker
        self.eventBus = eventBus
        self.testConfigurationProvider = testConfigurationProvider
        self.parserRegistry = parserRegistry
        self.settingsStoreProvider = settingsStoreProvider
        self.supportsStreamingWithToolsOverride = supportsStreamingWithToolsOverride ?? config.supportsStreamingWithTools
        self.providerName = config.providerName
        self.preservesCache = preservesCache
    }

    var supportsStreamingWithTools: Bool {
        supportsStreamingWithToolsOverride
    }

    var supportsNativeReasoning: Bool {
        config.supportsNativeReasoning
    }

    // MARK: - AIService

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        let historyInput = OpenRouterAIService.OpenRouterChatHistoryInput(
            messages: [OpenRouterChatMessage(role: "user", content: request.message)],
            tools: request.tools,
            mode: request.mode,
            projectRoot: request.projectRoot,
            runId: nil,
            stage: nil
        )
        return try await performChat(historyInput)
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        let openRouterMessages = buildOpenRouterMessages(from: request.messages, projectRoot: request.projectRoot)
        let historyInput = OpenRouterAIService.OpenRouterChatHistoryInput(
            messages: openRouterMessages,
            tools: request.tools,
            mode: request.mode,
            projectRoot: request.projectRoot,
            runId: request.runId,
            stage: request.stage
        )
        return try await performChat(historyInput)
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        let openRouterMessages = buildOpenRouterMessages(from: request.messages, projectRoot: request.projectRoot)
        let historyInput = OpenRouterAIService.OpenRouterChatHistoryInput(
            messages: openRouterMessages,
            tools: request.tools,
            mode: request.mode,
            projectRoot: request.projectRoot,
            runId: request.runId,
            stage: request.stage
        )
        if historyInput.tools?.isEmpty == false, !supportsStreamingWithTools {
            return try await performChat(historyInput)
        }
        return try await performStreamingChat(historyInput, runId: runId)
    }

    // MARK: - Non-streaming Chat

    private func performChat(_ request: OpenRouterAIService.OpenRouterChatHistoryInput) async throws -> AIServiceResponse {
        let preparation = try await buildChatPreparation(request: request)
        let settings = preparation.settings
        let toolDefs = preparation.toolDefinitions
        let toolChoice = preparation.toolChoice
        let reasoningConfig = preparation.nativeReasoningConfiguration
        let requestBody = OpenRouterChatRequest(
            model: client.effectiveModel(for: settings.model),
            messages: preparation.finalMessages,
            maxTokens: outputTokenBudget(stage: request.stage, hasTools: (toolDefs?.isEmpty == false)),
            temperature: nil,
            tools: toolDefs,
            toolChoice: toolChoice,
            parallelToolCalls: toolDefs != nil ? true : nil,
            reasoning: reasoningConfig.map(OpenRouterChatRequest.Reasoning.init),
            stream: false
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let body = try enc.encode(requestBody)
        let data = try await executeChatCompletion(apiKey: preparation.settings.apiKey, baseURL: preparation.settings.baseURL, body: body, requestId: preparation.requestId)
        let response = try await decodeResponse(data: data, requestId: preparation.requestId)

        guard let choice = response.choices.first else {
            throw AppError.aiServiceError("\(providerName) response was empty.")
        }

        if let usage = response.usage {
            try await usageTracker.publishUsageUpdate(usage: usage, modelId: preparation.settings.model, apiKey: preparation.settings.apiKey, baseURL: preparation.settings.baseURL, providerName: providerName, runId: request.runId)
        }

        await rateLimiter.registerSuccess()
        publishProviderIssueResolved()

        let resolvedToolCalls = recoverFallbackToolCalls(from: choice.message.content, structuredToolCalls: request.tools?.isEmpty == false ? choice.message.toolCalls : nil, toolsWereProvided: request.tools?.isEmpty == false)
        let sanitizedContent = sanitizeAssistantContent(contentExcludingRecoveredToolCalls(from: choice.message.content, recoveredToolCalls: resolvedToolCalls))

        let effectiveReasoning = choice.message.reasoning ?? choice.message.reasoningContent
        if let reasoning = effectiveReasoning, !reasoning.isEmpty {
        }

        return AIServiceResponse(
            content: sanitizedContent,
            toolCalls: resolvedToolCalls,
            reasoning: effectiveReasoning
        )
    }

    // MARK: - Streaming Chat

    private func performStreamingChat(_ request: OpenRouterAIService.OpenRouterChatHistoryInput, runId: String) async throws -> AIServiceResponse {
        let preparation = try await buildChatPreparation(request: request)
        let requestBody = OpenRouterChatRequest(
            model: client.effectiveModel(for: preparation.settings.model),
            messages: preparation.finalMessages,
            maxTokens: outputTokenBudget(stage: request.stage, hasTools: (preparation.toolDefinitions?.isEmpty == false)),
            temperature: nil,
            tools: preparation.toolDefinitions,
            toolChoice: preparation.toolChoice,
            parallelToolCalls: preparation.toolDefinitions != nil ? true : nil,
            reasoning: preparation.nativeReasoningConfiguration.map(OpenRouterChatRequest.Reasoning.init),
            stream: true
        )

        let enc2 = JSONEncoder()
        enc2.outputFormatting = [.sortedKeys]
        let body = try enc2.encode(requestBody)
        let collector = ChunkCollector()
        // Estimate prompt tokens from the request messages for context display
        let promptCharCount = preparation.finalMessages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        streamingPromptEstimate = max(1, promptCharCount / 4)
        // Publish initial estimate so the status bar shows the full context immediately
        let initialEstimate = streamingPromptEstimate
        Task { @MainActor in
            eventBus.publish(StreamingContextUsageEvent(
                runId: request.runId ?? UUID().uuidString,
                estimatedPromptTokens: initialEstimate
            ))
        }
        try await enforceRateLimit()

        let requestContext = config.buildRequestContext(baseURL: preparation.settings.baseURL)

        do {
            try await client.chatCompletionStreaming(apiKey: preparation.settings.apiKey, context: requestContext, body: body) { [weak self] chunkJson in
                guard let self else { return }
                let idx = collector.chunkCount
                collector.chunkCount += 1

                let lines = chunkJson.components(separatedBy: "\n")
                var anyParsed = false
                var lastReason: String?
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let chunkData = trimmed.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(OpenRouterChatResponseChunk.self, from: chunkData) else { continue }
                    anyParsed = true
                    if chunk.choices.first?.finishReason != nil {
                        lastReason = chunk.choices.first?.finishReason
                    }
                    if let usage = chunk.usage {
                        collector.setUsage(usage)
                    }
                    if let delta = chunk.choices.first?.delta {
                        if let reasoning = delta.reasoning ?? delta.reasoningContent {
                            collector.appendReasoningChunk(reasoning)
                            Task { @MainActor in
                                self.eventBus.publish(LocalModelStreamingReasoningChunkEvent(runId: runId, chunk: reasoning))
                            }
                        }
                        if let content = delta.content {
                            collector.appendChunk(content)
                            Task { @MainActor in
                                self.eventBus.publish(LocalModelStreamingChunkEvent(runId: runId, chunk: content))
                            }
                        }
                        if let newToolCalls = delta.toolCalls, !newToolCalls.isEmpty {
                            collector.appendToolCalls(newToolCalls)
                        }
                    }
                }
            }

        } catch {
            // Publish final estimate with isFinal on error too (so accumulated total is preserved)
            let finalEstimate = streamingPromptEstimate
            Task { @MainActor in
                eventBus.publish(StreamingContextUsageEvent(
                    runId: request.runId ?? UUID().uuidString,
                    estimatedPromptTokens: finalEstimate,
                    isFinal: true
                ))
            }
            try await handlePotentialRateLimit(error, requestId: preparation.requestId)
            throw error
        }

        // Streaming completed successfully — publish final estimate
        let finalEstimate = streamingPromptEstimate
        Task { @MainActor in
            eventBus.publish(StreamingContextUsageEvent(
                runId: request.runId ?? UUID().uuidString,
                estimatedPromptTokens: finalEstimate,
                isFinal: true
            ))
        }

        let assembled = collector.getResults()
        let reasoning = collector.getReasoning()
        let content = collector.getContent()
        if let reasoning, !reasoning.isEmpty {
        }
        let recoveredToolCalls = recoverFallbackToolCalls(from: content, structuredToolCalls: assembled.valid, toolsWereProvided: preparation.toolDefinitions?.isEmpty == false)
        let displayContent = contentExcludingRecoveredToolCalls(from: content, recoveredToolCalls: recoveredToolCalls)
        let fullContent = sanitizeAssistantContent(displayContent)

        if let usage = collector.getUsage() {
            try await usageTracker.publishUsageUpdate(usage: usage, modelId: preparation.settings.model, apiKey: preparation.settings.apiKey, baseURL: preparation.settings.baseURL, providerName: providerName, runId: request.runId)
        }

        await rateLimiter.registerSuccess()
        publishProviderIssueResolved()

        return AIServiceResponse(
            content: fullContent,
            toolCalls: recoveredToolCalls,
            reasoning: reasoning,
            malformedToolCalls: assembled.malformed.isEmpty ? nil : assembled.malformed
        )
    }

    // MARK: - Chat Preparation (delegates to shared logic via OpenRouterAIService+ChatPreparation)

    func buildChatPreparation(request: OpenRouterAIService.OpenRouterChatHistoryInput) async throws -> OpenRouterAIService.ChatPreparation {
        let requestId = UUID().uuidString
        let settings = loadSettingsSnapshot()
        try validateSettings(apiKey: settings.apiKey, model: settings.model)

        // L5a: Build repo-map for agent/coder mode (cached, async).
        // Skip for large projects (>500 source files) — scanning would block the request.
        let repoMap = if request.mode?.isAgentic == true,
                        let projectRoot = request.projectRoot,
                        RepoMapBuilder.fileCount(projectRoot: projectRoot) <= 500 {
            try? await RepoMapBuilder.cachedMap(projectRoot: projectRoot)
        } else { nil as String? }

        let systemContent = try buildSystemContent(input: .init(
            systemPrompt: settings.systemPrompt,
            hasTools: request.tools?.isEmpty == false,
            toolPromptMode: settings.toolPromptMode,
            mode: request.mode,
            projectRoot: request.projectRoot,
            reasoningMode: settings.reasoningMode,
            stage: request.stage,
            useNativeReasoning: supportsNativeReasoning,
            repoMap: repoMap
        ))
        let finalMessages = buildFinalMessages(
            systemContent: systemContent,
            messages: request.messages,
            emitCacheControl: Self.isAnthropicModel(client.effectiveModel(for: settings.model))
        )
        let toolDefinitions = buildToolDefinitions(tools: request.tools)
        let toolChoice = toolDefinitions?.isEmpty == false ? "auto" : nil
        return OpenRouterAIService.ChatPreparation(
            requestId: requestId,
            settings: settings,
            finalMessages: finalMessages,
            toolDefinitions: toolDefinitions,
            toolChoice: toolChoice,
            nativeReasoningConfiguration: supportsNativeReasoning ? nativeReasoningConfiguration(for: settings.reasoningMode) : nil
        )
    }

    // MARK: - Settings

    private func loadSettingsSnapshot() -> OpenRouterAIService.SettingsSnapshot {
        let store = resolveSettingsStore()
        let settings = store.load(includeApiKey: true)
        return OpenRouterAIService.SettingsSnapshot(
            apiKey: settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: settings.baseURL,
            reasoningMode: settings.reasoningMode,
            toolPromptMode: settings.toolPromptMode
        )
    }

    private func resolveSettingsStore() -> any OpenRouterSettingsLoading {
        settingsStoreProvider()
    }

    private func validateSettings(apiKey: String, model: String) throws {
        let isCustomEndpoint = providerName == "Custom Endpoint"
        if !isCustomEndpoint, apiKey.isEmpty {
            throw AppError.aiServiceError("\(providerName) API key is missing.")
        }
        guard !model.isEmpty else { throw AppError.aiServiceError("\(providerName) model is not set.") }
    }

    private func buildSystemContent(input: OpenRouterAIService.BuildSystemContentInput) throws -> String {
        let pinnedRules: [String] = {
            if let root = input.projectRoot { return PinnedRulesStore.load(projectRoot: root) }
            return []
        }()
        return try SystemPromptAssembler().assemble(input: .init(
            systemPromptOverride: input.systemPrompt,
            hasTools: input.hasTools,
            toolPromptMode: input.toolPromptMode,
            mode: input.mode,
            projectRoot: input.projectRoot,
            reasoningMode: input.reasoningMode,
            stage: input.stage,
            includeModelReasoning: !input.useNativeReasoning,
            pinnedRules: pinnedRules,
            repoMap: input.repoMap
        ))
    }

    private func nativeReasoningConfiguration(for reasoningMode: ReasoningMode) -> OpenRouterAIService.NativeReasoningConfiguration? {
        let effort = ReasoningIntensity.current.apiEffortValue
        switch reasoningMode {
        case .none: return .init(enabled: false, effort: "none", exclude: true)
        case .model: return .init(enabled: true, effort: effort, exclude: true)
        case .agent: return .init(enabled: false, effort: "none", exclude: true)
        case .modelAndAgent: return .init(enabled: true, effort: effort, exclude: true)
        }
    }

    private func buildFinalMessages(
        systemContent: String?,
        messages: [OpenRouterChatMessage],
        emitCacheControl: Bool
    ) -> [OpenRouterChatMessage] {
        // The system block is the protected, stable prefix. Marking it with a
        // cache breakpoint lets the provider reuse its prefix across turns
        // (Anthropic/OpenRouter). The system content is made stage-independent
        // in SystemPromptAssembler, so this prefix never changes -> cache hits.
        //
        // NOTE: `context` (auto-retrieved RAG) is intentionally NOT prepended.
        // RAG is exposed as the ContextTool and invoked by the model on demand;
        // force-injecting it here scrambles the stable prefix every turn.
        let systemMessage = OpenRouterChatMessage(
            role: "system",
            content: systemContent,
            cacheControl: emitCacheControl ? CacheControl() : nil
        )
        var finalMessages = [systemMessage]

        if emitCacheControl {
            // P2: second cache breakpoint at the end of the STABLE turn prefix.
            // The conversation prefix up to the most recent user turn (the
            // accumulated tool history) never changes while a node loops, so
            // marking the message just before the newest user message lets the
            // provider reuse it across iterations instead of re-prefilling the
            // whole chain. Everything after that point (current turn) streams
            // fresh. This is the message AFTER the newest user message's
            // predecessor: for Anthropic, cache_control marks the END of the
            // cached segment.
            var newestUserIndex = -1
            for (i, m) in messages.enumerated() where m.role == "user" {
                newestUserIndex = i
            }
            if newestUserIndex > 0 {
                finalMessages.append(contentsOf: messages[0..<newestUserIndex])
                let base = messages[newestUserIndex - 1]
                let breakpointMessage = OpenRouterChatMessage(
                    role: base.role,
                    content: base.content,
                    toolCallID: base.toolCallID,
                    toolCalls: base.toolCalls,
                    reasoningContent: base.reasoningContent,
                    cacheControl: CacheControl()
                )
                finalMessages.append(breakpointMessage)
                finalMessages.append(contentsOf: messages[newestUserIndex...])
            } else {
                finalMessages.append(contentsOf: messages)
            }
        } else {
            finalMessages.append(contentsOf: messages)
        }
        return finalMessages
    }

    /// Anthropic-family models (routed directly or via OpenRouter) support
    /// explicit `cache_control` breakpoints. Other providers cache the stable
    /// prefix automatically, so no marker is needed there.
    private static func isAnthropicModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("anthropic") || m.contains("claude")
    }

    private func buildToolDefinitions(tools: [AITool]?) -> [[String: Any]]? {
        tools?.map { tool in
            ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters]]
        }
    }

    // MARK: - Message Mapping

    private func buildOpenRouterMessages(from messages: [ChatMessage], projectRoot: URL?) -> [OpenRouterChatMessage] {
        guard !preservesCache else {
            let allIDs = Set(messages.compactMap { $0.toolCallId }.filter { !$0.isEmpty })
            return messages.compactMap { message in
                mapOpenRouterChatMessage(message, validToolCallIds: allIDs, model: "", projectRoot: nil)
            }
        }

        let model = loadSettingsSnapshot().model
        let validToolCallIds = buildValidToolCallIds(from: messages)
        // Reasoning stays per-message — backfilling the last message's
        // reasoning into every historical assistant message bloats context.
        return messages.compactMap { message in
            mapOpenRouterChatMessage(message, validToolCallIds: validToolCallIds, model: model, projectRoot: projectRoot)
        }
    }

    private func buildValidToolCallIds(from messages: [ChatMessage]) -> Set<String> {
        Set(messages.compactMap { $0.toolCalls }.flatMap { $0 }.map { $0.id })
    }

    private func mapOpenRouterChatMessage(_ message: ChatMessage, validToolCallIds: Set<String>, model: String, projectRoot: URL?) -> OpenRouterChatMessage? {
        switch message.role {
        case .user:
            return OpenRouterChatMessage(role: "user", content: message.content)
        case .assistant:
            if let toolCalls = message.toolCalls {
                return OpenRouterChatMessage(role: "assistant", content: message.content.isEmpty ? "" : message.content, toolCalls: toolCalls, reasoningContent: message.reasoning)
            }
            return OpenRouterChatMessage(role: "assistant", content: message.content, reasoningContent: message.reasoning)
        case .system:
            return OpenRouterChatMessage(role: "system", content: message.content)
        case .tool:
            return mapToolMessage(message, validToolCallIds: validToolCallIds, model: model, projectRoot: projectRoot)
        }
    }

    private func mapToolMessage(_ message: ChatMessage, validToolCallIds: Set<String>, model: String, projectRoot: URL?) -> OpenRouterChatMessage? {
        guard message.toolStatus != .executing else { return nil }
        // Strip the JSON metadata envelope — the model only needs the first-line
        // envelope + actual payload. The full JSON is for system parsers only.
        let modelContent = ToolExecutionEnvelope.modelFacingContent(from: message.content)
        if preservesCache {
            let toolCallId = message.toolCallId ?? message.toolName ?? UUID().uuidString
            return OpenRouterChatMessage(role: "tool", content: modelContent, toolCallID: toolCallId)
        }
        if let toolCallId = message.toolCallId {
            return mapValidToolMessage(message, toolCallId: toolCallId, validToolCallIds: validToolCallIds, model: model, projectRoot: projectRoot, modelContent: modelContent)
        }
        return mapFallbackToolMessage(message, model: model, projectRoot: projectRoot, modelContent: modelContent)
    }

    private func mapValidToolMessage(_ message: ChatMessage, toolCallId: String, validToolCallIds: Set<String>, model: String, projectRoot: URL?, modelContent: String) -> OpenRouterChatMessage? {
        guard validToolCallIds.contains(toolCallId) else { return nil }
        return OpenRouterChatMessage(role: "tool", content: modelContent, toolCallID: toolCallId)
    }

    private func mapFallbackToolMessage(_ message: ChatMessage, model: String, projectRoot: URL?, modelContent: String) -> OpenRouterChatMessage {
        let toolCallId = message.toolCallId ?? message.toolName ?? UUID().uuidString
        return OpenRouterChatMessage(role: "user", content: "Tool Output: \(modelContent)")
    }

    // MARK: - Execution & Rate Limiting

    private func executeChatCompletion(apiKey: String, baseURL: String, body: Data, requestId: String) async throws -> Data {
        try await enforceRateLimit()
        let config = await testConfigurationProvider.configuration
        do {
            let requestContext = self.config.buildRequestContext(baseURL: baseURL)
            return try await executeWithTimeout(timeoutSeconds: max(config.externalAPITimeout, 1), requestId: requestId) {
                try await self.client.chatCompletion(apiKey: apiKey, context: requestContext, body: body)
            }
        } catch {
            if let openRouterError = error as? OpenRouterServiceError {
                if case let .serverError(code, body) = openRouterError {
                    let snippet = String((body ?? "").prefix(2000))
                    await logRequestError(requestId: requestId, status: code, bodySnippet: snippet)
                }
            }
            try await handlePotentialRateLimit(error, requestId: requestId)
            publishProviderFailureIfNeeded(error)
            throw error
        }
    }

    private func executeWithTimeout<T: Sendable>(timeoutSeconds: TimeInterval, requestId: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let name = providerName
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppError.aiServiceError("\(name) request timed out after \(Int(timeoutSeconds))s (requestId: \(requestId))")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AppError.aiServiceError("\(name) request ended without a result (requestId: \(requestId))")
            }
            return result
        }
    }

    private func enforceRateLimit() async throws {
        let config = await testConfigurationProvider.configuration
        guard config.allowExternalAPIs else {
            throw AppError.aiServiceError("External APIs are disabled in test configuration")
        }
        let now = Date()
        let effectiveInterval = max(0.5, config.minAPIRequestInterval)
        let reservation = await rateLimiter.reserveWait(minimumInterval: effectiveInterval, now: now)
        if reservation.waitTime > 0 {
            if reservation.isProviderCooldown {
                eventBus.publish(ProviderIssueStatusEvent(providerName: providerName, statusKind: .rateLimited, statusCode: nil, message: "Provider cooldown active. Waiting before the next request.", cooldownUntil: now.addingTimeInterval(reservation.waitTime)))
            }
            try await Task.sleep(nanoseconds: UInt64(reservation.waitTime * 1_000_000_000))
        }
    }

    private func handlePotentialRateLimit(_ error: Error, requestId: String) async throws {
        guard let serviceError = error as? OpenRouterServiceError,
              case let .serverError(code, _) = serviceError,
              isProviderRateLimitStatus(code) else { return }
        let cooldownDuration = await rateLimiter.registerRateLimit(statusCode: code)
        await AppLogger.shared.error(category: .ai, message: "openrouter.rate_limit_hit", context: AppLogger.LogCallContext(metadata: ["requestId": requestId, "statusCode": code, "retrySuggested": true, "providerCooldownSeconds": Int(cooldownDuration)]))
        let cooldownUntil = Date().addingTimeInterval(cooldownDuration)
        let issueMessage = providerIssueMessage(for: serviceError, fallback: "Provider rate limit hit. Retrying when cooldown ends.")
        eventBus.publish(ProviderIssueStatusEvent(providerName: providerName, statusKind: .rateLimited, statusCode: code, message: issueMessage, cooldownUntil: cooldownUntil))
    }

    private func isProviderRateLimitStatus(_ statusCode: Int) -> Bool {
        statusCode == 421 || statusCode == 429
    }

    // MARK: - Provider Issue Events

    private func publishProviderFailureIfNeeded(_ error: Error) {
        guard let serviceError = error as? OpenRouterServiceError else { return }
        let resolvedIssueStatus = providerIssueStatus(for: serviceError)
        let issueMessage = providerIssueMessage(for: serviceError, fallback: error.localizedDescription)
        eventBus.publish(ProviderIssueStatusEvent(providerName: providerName, statusKind: resolvedIssueStatus.kind, statusCode: resolvedIssueStatus.statusCode, message: issueMessage, cooldownUntil: nil))
    }

    private func publishProviderIssueResolved() {
        eventBus.publish(ProviderIssueStatusEvent(providerName: providerName, statusKind: .resolved, statusCode: nil, message: "", cooldownUntil: nil))
    }

    private func providerIssueStatus(for error: OpenRouterServiceError) -> (kind: ProviderIssueStatusEvent.StatusKind, statusCode: Int?) {
        switch error {
        case let .serverError(code, _):
            switch code {
            case 401, 403: return (.authentication, code)
            case 402: return (.insufficientBalance, code)
            case 421, 429: return (.rateLimited, code)
            case 500...599: return (.unavailable, code)
            default: return (.unknown, code)
            }
        default: return (.transport, nil)
        }
    }

    private func providerIssueMessage(for error: OpenRouterServiceError, fallback: String) -> String {
        switch error {
        case let .serverError(code, body):
            if code == 402, let insufficientBalanceMessage = insufficientBalanceMessage(from: body) { return insufficientBalanceMessage }
            let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedBody.isEmpty ? fallback : trimmedBody
        default: return fallback
        }
    }

    private func insufficientBalanceMessage(from body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObject = jsonObject["error"] as? [String: Any] else { return nil }
        let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = errorObject["metadata"] as? [String: Any]
        let buyCreditsURL = (metadata?["buyCreditsUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty, let buyCreditsURL, !buyCreditsURL.isEmpty { return "\(message) Add credits: \(buyCreditsURL)" }
        return message
    }

    // MARK: - Response Decoding

    private func decodeResponse(data: Data, requestId: String) async throws -> OpenRouterChatResponse {
        do {
            return try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            if let errorMessage = OpenRouterAIService.decodeErrorMessage(from: data) {
                await AppLogger.shared.error(category: .ai, message: "openrouter.response_error", context: AppLogger.LogCallContext(metadata: ["requestId": requestId, "error": errorMessage]))
                throw AppError.aiServiceError(errorMessage)
            }
            let bodySnippet = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            await AppLogger.shared.error(category: .ai, message: "openrouter.decode_error", context: AppLogger.LogCallContext(metadata: ["requestId": requestId, "error": error.localizedDescription, "bodySnippet": bodySnippet]))
            eventBus.publish(ProviderIssueStatusEvent(providerName: providerName, statusKind: .unknown, statusCode: nil, message: "Failed to decode provider response.", cooldownUntil: nil))
            throw AppError.aiServiceError("Failed to decode \(providerName) response: \(error.localizedDescription)")
        }
    }

    func decodeOpenRouterErrorMessage(from data: Data) -> String? {
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

    // MARK: - Tool Call Recovery

    private func recoverFallbackToolCalls(from content: String?, structuredToolCalls: [AIToolCall]?, toolsWereProvided: Bool) -> [AIToolCall]? {
        let calls: [AIToolCall]?
        if let structuredToolCalls, !structuredToolCalls.isEmpty {
            calls = structuredToolCalls
        } else if toolsWereProvided, let content, !content.isEmpty {
            calls = decodeFallbackToolCalls(from: content)
        } else {
            calls = nil
        }
        guard let calls else { return nil }
        // Normalize names through the alias registry so every downstream consumer
        // (loop logic, unavailable-tool detection, execution) sees canonical names.
        // The fallback parser already normalizes; applying it again is idempotent.
        let normalized = calls.map { normalizeToolCall($0) }
        return normalized.isEmpty ? nil : normalized
    }

    private func decodeFallbackToolCalls(from content: String) -> [AIToolCall]? {
        parserRegistry.decodeToolCalls(from: content)
    }

    private func normalizeToolCall(_ call: AIToolCall) -> AIToolCall {
        AIToolCall(id: call.id, name: ParserHelper.normalizeName(call.name), arguments: call.arguments)
    }

    private func contentExcludingRecoveredToolCalls(from content: String?, recoveredToolCalls: [AIToolCall]?) -> String? {
        guard let content else { return nil }
        return ToolMarkupStripper.stripMarkup(from: content)
    }

    private func sanitizeAssistantContent(_ content: String?) -> String? {
        guard let content else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Token Budget

    private func outputTokenBudget(stage: AIRequestStage?, hasTools: Bool) -> Int {
        // Qwen 3.5 4B supports up to 32K output tokens; budgets below are
        // generous enough to avoid mid-generation truncation of tool calls.
        switch stage {
        case .tool_loop: return hasTools ? 4096 : 1024
        case .final_response: return 2048
        case .initial_response: return hasTools ? 1024 : 640
        case .qa_tool_output_review, .qa_quality_review: return 1024
        case .warmup, .other, .none: return hasTools ? 1024 : 640
        }
    }

    // MARK: - Logging

    private func logRequestError(requestId: String, status: Int, bodySnippet: String) async {
        await AppLogger.shared.error(category: .ai, message: "openrouter.request_error", context: AppLogger.LogCallContext(metadata: ["requestId": requestId, "status": status, "bodySnippet": bodySnippet]))
        await AIToolTraceLogger.shared.log(type: "openrouter.error", data: ["status": status, "bodySnippet": bodySnippet])
    }
}

// MARK: - ChunkCollector (thread-safe)

private final class ChunkCollector: @unchecked Sendable {
    private var chunks: [String] = []
    private var chunkCountValue: Int = 0
    private var reasoningChunks: [String] = []
    private var usage: OpenRouterChatUsage?
    private var toolCallsDrafts: [Int: ToolCallDraft] = [:]
    private let lock = NSLock()

    struct ToolCallDraft {
        var id: String; var type: String; var name: String; var arguments: String
    }

    var chunkCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return chunkCountValue }
        set { lock.lock(); chunkCountValue = newValue; lock.unlock() }
    }

    func appendChunk(_ content: String) { lock.lock(); chunks.append(content); lock.unlock() }
    func appendReasoningChunk(_ content: String) { lock.lock(); reasoningChunks.append(content); lock.unlock() }
    func setUsage(_ u: OpenRouterChatUsage) { lock.lock(); usage = u; lock.unlock() }

    func appendToolCalls(_ calls: [OpenRouterChatResponseChunkToolCall]) {
        lock.lock()
        for call in calls {
            var draft = toolCallsDrafts[call.index] ?? ToolCallDraft(id: "", type: "function", name: "", arguments: "")
            if let id = call.id { draft.id = id }
            if let type = call.type { draft.type = type }
            if let name = call.function?.name { draft.name = name }
            if let args = call.function?.arguments { draft.arguments += args }
            toolCallsDrafts[call.index] = draft
        }
        lock.unlock()
    }

    func getResults() -> AssembledToolCalls {
        lock.lock()
        defer { lock.unlock() }
        let drafts: [ToolArgumentDraft] = toolCallsDrafts.sorted(by: { $0.key < $1.key }).map { (_, draft) in
            ToolArgumentDraft(id: draft.id, name: draft.name, arguments: draft.arguments)
        }
        return ToolArgumentParser.assemble(drafts)
    }

    func getUsage() -> OpenRouterChatUsage? {
        lock.lock(); defer { lock.unlock() }
        return usage
    }

    func getReasoning() -> String? {
        lock.lock(); defer { lock.unlock() }
        return reasoningChunks.joined().isEmpty ? nil : reasoningChunks.joined()
    }

    func getContent() -> String {
        lock.lock(); defer { lock.unlock() }
        return chunks.joined()
    }
}
