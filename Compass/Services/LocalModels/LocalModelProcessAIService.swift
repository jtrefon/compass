import Foundation
import Combine
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

actor LocalModelProcessAIService: AIService {
    nonisolated let preservesCache: Bool = true

    typealias MemoryPressureObserverFactory = @Sendable (@escaping @Sendable () -> Void) -> (any MemoryPressureObserving)?

    private struct DefaultSamplingParameters {
        let temperature: Float
        let topP: Float
        let repetitionPenalty: Float?
        let repetitionContextSize: Int
    }

    struct NoOpEventBus: EventBusProtocol {
        func publish<E: Event>(_ event: E) {}

        func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable {
            AnyCancellable {}
        }
    }

    protocol ModelFileStoring: Sendable {
        func isModelInstalled(_ model: LocalModelDefinition) -> Bool
        func modelDirectory(modelId: String) throws -> URL
        func chatRuntimeModelDirectory() throws -> URL
    }

    struct LocalModelFileStoreAdapter: ModelFileStoring {
        func isModelInstalled(_ model: LocalModelDefinition) -> Bool {
            LocalModelFileStore.isModelInstalled(model)
        }

        func modelDirectory(modelId: String) throws -> URL {
            try LocalModelFileStore.modelDirectory(modelId: modelId)
        }

        func chatRuntimeModelDirectory() throws -> URL {
            try LocalModelFileStore.chatRuntimeModelDirectory()
        }
    }


    private let selectionStore: LocalModelSelectionStore
    private let fileStore: ModelFileStoring
    private let generator: LocalModelGenerating
    private let settingsStore: any OpenRouterSettingsLoading
    private let promptBuilder: LocalModelPromptBuilder
    private var memoryPressureObserver: (any MemoryPressureObserving)?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let prefixCache = PromptPrefixCache()
    private let activityCoordinator: (any AgentActivityCoordinating)?
    private let launchContext: AppLaunchContext
    private var cachedTokenizer: (directory: URL, tokenizer: any Tokenizers.Tokenizer)?
    private var tokenizerLoadInFlight: Task<(URL, any Tokenizers.Tokenizer)?, Never>?

    init(
        selectionStore: LocalModelSelectionStore = LocalModelSelectionStore(),
        fileStore: ModelFileStoring = LocalModelFileStoreAdapter(),
        generator: LocalModelGenerating? = nil,
        eventBus: EventBusProtocol? = nil,
        settingsStore: any OpenRouterSettingsLoading = OpenRouterSettingsStore(),
        memoryPressureObserverFactory: MemoryPressureObserverFactory = { callback in
            MemoryPressureObserver(onMemoryPressure: callback)
        },
        activityCoordinator: (any AgentActivityCoordinating)? = nil,
        launchContext: AppLaunchContext = AppRuntimeEnvironment.launchContext
    ) {
        self.selectionStore = selectionStore
        self.fileStore = fileStore
        let resolvedEventBus = eventBus ?? NoOpEventBus()
        self.generator = generator ?? NativeMLXGenerator(eventBus: resolvedEventBus)
        self.settingsStore = settingsStore
        self.promptBuilder = LocalModelPromptBuilder()
        self.memoryPressureObserver = nil
        self.activityCoordinator = activityCoordinator
        self.launchContext = launchContext
        let generatorForPressureHandling = self.generator
        let prefixCacheForPressureHandling = self.prefixCache

        // Register for memory pressure notifications
        self.memoryPressureObserver = memoryPressureObserverFactory {
            Task {
                await AppLogger.shared.warning(
                    category: .localModel,
                    message: "memory_pressure_unload",
                    context: AppLogger.LogCallContext(metadata: [
                        "timestamp": ISO8601DateFormatter().string(from: Date())
                    ])
                )
                if let mlxGenerator = generatorForPressureHandling as? NativeMLXGenerator {
                    await mlxGenerator.unloadAllModels(reason: "memory_pressure")
                }
                // FIM and any other inference services release their containers too.
                await InferenceUnloadRegistry.shared.unloadAll()
                // Also clear prefix cache on memory pressure
                await prefixCacheForPressureHandling.clearAll()
            }
        }
        if !launchContext.isTesting {
            Task {
                await registerLifecycleObservers()
                await preloadSelectedModelIfNeeded()
            }
        }
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        try await sendMessage(AIServiceHistoryRequest(
            messages: [ChatMessage(role: .user, content: request.message, mediaAttachments: request.mediaAttachments)],
            mediaAttachments: request.mediaAttachments,
            context: request.context,
            tools: request.tools,
            mode: request.mode,
            projectRoot: request.projectRoot
        ))
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        let modelId = await selectionStore.selectedModelId()
        guard !modelId.isEmpty else {
            throw AppError.aiServiceError("No local model selected.")
        }
        guard let model = LocalModelCatalog.model(id: modelId) else {
            throw AppError.aiServiceError("Selected local model is not recognized: \(modelId)")
        }
        guard fileStore.isModelInstalled(model) else {
            throw AppError.aiServiceError("Local model is not downloaded: \(model.displayName)")
        }

        let modelDirectory = try fileStore.chatRuntimeModelDirectory()
        ensureTokenizerLoaded(modelDirectory: modelDirectory)
        let storedContextLength = await selectionStore.contextLength()
        let kvCache4BitEnabled = await selectionStore.isKVCache4BitEnabled()
        let effectiveKVCache4Bit = kvCache4BitEnabled && model.supportsQuantizedKVCache
        let testBudget = LocalModelTestBudget.applyIfNeeded(
            to: request,
            contextLength: storedContextLength ?? LocalModelFileStore.contextLength(for: model),
            launchContext: launchContext
        )
        let defaultSampling = promptBuilder.defaultSamplingParameters(
            mode: request.mode,
            stage: request.stage
        )
        let inferenceConfiguration = await LocalModelInferenceOverrides.shared.resolve(
            defaultContextLength: testBudget.contextLength,
            defaultMaxOutputTokens: testBudget.maxOutputTokens,
            defaultTemperature: defaultSampling.temperature,
            defaultTopP: defaultSampling.topP,
            defaultRepetitionPenalty: defaultSampling.repetitionPenalty,
            defaultRepetitionContextSize: defaultSampling.repetitionContextSize,
            defaultKVCache4BitEnabled: effectiveKVCache4Bit
        )
        let safeInferenceConfiguration = model.supportsQuantizedKVCache
            ? inferenceConfiguration
            : LocalModelInferenceConfiguration(
                contextLength: inferenceConfiguration.contextLength,
                maxKVSize: inferenceConfiguration.maxKVSize,
                maxOutputTokens: inferenceConfiguration.maxOutputTokens,
                prefillStepSize: inferenceConfiguration.prefillStepSize,
                temperature: inferenceConfiguration.temperature,
                topP: inferenceConfiguration.topP,
                repetitionPenalty: inferenceConfiguration.repetitionPenalty,
                repetitionContextSize: inferenceConfiguration.repetitionContextSize,
                kvCache4BitEnabled: false
            )
        let isTesting = launchContext.isTesting
        let settings = settingsStore.load(includeApiKey: false)
        
        // Build system content for caching
        let systemContent = try promptBuilder.buildSystemContent(
            tools: request.tools,
            mode: request.mode,
            stage: request.stage,
            projectRoot: request.projectRoot,
            settings: settings
        )
        
        // Check prefix cache for this conversation
        let conversationId = request.conversationId
        if !isTesting, let conversationId = conversationId {
            let cachedPrefix = await prefixCache.getCachedPrefix(
                conversationId: conversationId,
                modelId: modelId,
                systemPrompt: systemContent,
                tools: request.tools,
                mode: request.mode
            )
            
            if cachedPrefix != nil {
                // Cache hit - the prefix is validated and can be used
                // The actual benefit is tracking; MLX handles tokenization internally
                let stats = await prefixCache.getStatistics()
                await AppLogger.shared.debug(
                    category: .localModel,
                    message: "prefix_cache_hit",
                    context: AppLogger.LogCallContext(metadata: [
                        "conversationId": conversationId,
                        "hitRate": String(format: "%.1f%%", stats.hitRate * 100)
                    ])
                )
            }
        }
        
        let budgetedMessages = promptBuilder.budgetMessages(
            testBudget.retainedMessages,
            explicitContext: request.context,
            systemContent: systemContent,
            inferenceConfiguration: inferenceConfiguration,
            approximateTokenCount: { [self] in approximateTokenCount($0) }
        )
        let chatMessages = promptBuilder.buildChatMessages(
            messages: budgetedMessages,
            explicitContext: request.context,
            systemContent: systemContent,
            modelID: modelId,
            projectRoot: request.projectRoot
        )
        
        // Convert AITool to ToolSpec for MLXLLM
        let toolSpecs = promptBuilder.convertToToolSpec(request.tools)
        
        // TELEMETRY: Log what we're sending to the model for tool calling diagnosis
        await logToolCallingTelemetry(
            modelId: modelId,
            modelToolCallFormat: .json,
            toolSpecs: toolSpecs,
            systemContentLength: systemContent.count,
            messageCount: chatMessages.count
        )
        await AIToolTraceLogger.shared.log(type: "mlx.send_message", data: [
            "runId": request.runId ?? "",
            "modelId": modelId,
            "systemPromptChars": systemContent.count,
            "systemPromptApproxTokens": approximateTokenCount(systemContent),
            "messageCount": chatMessages.count,
            "toolCount": toolSpecs?.count ?? 0,
            "mode": request.mode?.rawValue ?? "unknown",
            "stage": request.stage?.rawValue ?? "unknown",
            "contextLength": safeInferenceConfiguration.contextLength,
            "maxOutputTokens": safeInferenceConfiguration.maxOutputTokens,
            "maxKVSize": safeInferenceConfiguration.maxKVSize,
            "prefillStepSize": safeInferenceConfiguration.prefillStepSize,
            "kvCache4Bit": safeInferenceConfiguration.kvCache4BitEnabled,
            "cacheKind": safeInferenceConfiguration.cacheKind,
            "conversationId": conversationId ?? ""
        ])

        let additionalContext = promptBuilder.additionalContext(
            for: model,
            settings: settings,
            stage: request.stage
        )
        let rawMessages = promptBuilder.buildRawMessages(
            messages: budgetedMessages,
            explicitContext: request.context,
            systemContent: systemContent,
            modelID: modelId,
            projectRoot: request.projectRoot
        )
        let allImages: [UserInput.Image] = budgetedMessages.flatMap { message in
            message.mediaAttachments.compactMap { attachment in
                guard attachment.kind == .image else { return nil }
                return UserInput.Image.url(attachment.url)
            }
        }
        let allVideos: [UserInput.Video] = budgetedMessages.flatMap { message in
            message.mediaAttachments.compactMap { attachment in
                guard attachment.kind == .video else { return nil }
                return UserInput.Video.url(attachment.url)
            }
        }
        // Wrap MLX inference with power management to prevent sleep during long generations
        let response: AIServiceResponse
        let capturedGenerator = self.generator
        let capturedUserInput = UnsafeValue(value: UserInput(
            messages: rawMessages, images: allImages, videos: allVideos,
            tools: toolSpecs, additionalContext: additionalContext
        ))
        if let coordinator = activityCoordinator {
            response = try await coordinator.withActivity(type: .mlxInference) {
                try await capturedGenerator.generate(
                    modelId: model.id,
                    modelDirectory: modelDirectory,
                    userInput: capturedUserInput.value,
                    tools: toolSpecs,
                    toolCallFormat: .json,
                    runId: request.runId,
                    inferenceConfiguration: safeInferenceConfiguration,
                    conversationId: conversationId
                )
            }
        } else {
            response = try await capturedGenerator.generate(
                modelId: model.id,
                modelDirectory: modelDirectory,
                userInput: capturedUserInput.value,
                tools: toolSpecs,
                toolCallFormat: .json,
                runId: request.runId,
                inferenceConfiguration: safeInferenceConfiguration,
                conversationId: conversationId
            )
        }
        
        // TELEMETRY: Log what we got back from the model
        await logResponseTelemetry(
            modelId: modelId,
            response: response,
            toolCount: toolSpecs?.count ?? 0
        )
        
        // Store prefix in cache for future turns
        if !isTesting, let conversationId = conversationId {
            await prefixCache.storePrefix(
                conversationId: conversationId,
                modelId: modelId,
                systemPrompt: systemContent,
                tools: request.tools,
                mode: request.mode
            )
        } else if isTesting {
            await prefixCache.clearAll()
        }
        
        return response
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        try await sendMessage(request)
    }

    func preloadSelectedModelIfNeeded() async {
        guard await selectionStore.isOfflineModeEnabled() else { return }
        await preloadCurrentSelection(unloadExistingModels: false)
    }

    func explainCode(_ code: String) async throws -> String {
        let prompt = "Explain the following code in clear, concise terms:\n\n\(code)"
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: prompt,
            context: nil,
            tools: nil,
            mode: nil,
            projectRoot: nil
        ))
        return response.content ?? ""
    }

    func refactorCode(_ code: String, instructions: String) async throws -> String {
        let prompt = "Refactor this code using the following instructions:\n\(instructions)\n\nCode:\n\(code)"
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: prompt,
            context: nil,
            tools: nil,
            mode: nil,
            projectRoot: nil
        ))
        return response.content ?? ""
    }

    func generateCode(_ prompt: String) async throws -> String {
        let message = "Generate code for the following request:\n\(prompt)"
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: message,
            context: nil,
            tools: nil,
            mode: nil,
            projectRoot: nil
        ))
        return response.content ?? ""
    }

    func fixCode(_ code: String, error: String) async throws -> String {
        let prompt = "Fix this code. Error message:\n\(error)\n\nCode:\n\(code)"
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: prompt,
            context: nil,
            tools: nil,
            mode: nil,
            projectRoot: nil
        ))
        return response.content ?? ""
    }

    private func approximateTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if let cached = cachedTokenizer {
            return cached.tokenizer.encode(text: text, addSpecialTokens: false).count
        }
        return max(1, (text.count + 3) / 4)
    }

    private func ensureTokenizerLoaded(modelDirectory: URL) {
        if cachedTokenizer != nil { return }
        if tokenizerLoadInFlight != nil { return }
        let dir = modelDirectory
        tokenizerLoadInFlight = Task<(URL, any Tokenizers.Tokenizer)?, Never> {
            do {
                let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
                return (dir, tokenizer)
            } catch {
                return nil
            }
        }
        Task { [weak self] in
            guard let self else { return }
            if let result = await self.tokenizerLoadInFlight?.value {
                await self.setCachedTokenizer(result.0, result.1)
            } else {
                await self.clearTokenizerLoadInFlight()
            }
        }
    }

    private func clearTokenizerLoadInFlight() {
        tokenizerLoadInFlight = nil
    }

    private func setCachedTokenizer(_ directory: URL, _ tokenizer: any Tokenizers.Tokenizer) {
        if let existing = cachedTokenizer, existing.directory == directory { return }
        cachedTokenizer = (directory, tokenizer)
        tokenizerLoadInFlight = nil
    }

    private func registerLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }

        let offlineObserver = NotificationCenter.default.addObserver(
            forName: .localModelOfflineModeDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let enabled = notification.userInfo?["enabled"] as? Bool ?? false
            Task {
                await self.handleOfflineModeChanged(enabled: enabled)
            }
        }
        let selectionObserver = NotificationCenter.default.addObserver(
            forName: .localModelSelectionDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleSelectedModelChanged()
            }
        }
        lifecycleObservers = [offlineObserver, selectionObserver]
    }

    private func handleOfflineModeChanged(enabled: Bool) async {
        if enabled {
            await preloadCurrentSelection(unloadExistingModels: true)
            return
        }
        if let nativeGenerator = generator as? NativeMLXGenerator {
            await nativeGenerator.unloadAllModels(reason: "offline_mode_disabled")
        }
    }

    private func handleSelectedModelChanged() async {
        guard await selectionStore.isOfflineModeEnabled() else { return }
        await preloadCurrentSelection(unloadExistingModels: true)
    }

    private func preloadCurrentSelection(unloadExistingModels: Bool) async {
        let modelId = await selectionStore.selectedModelId()
        guard !modelId.isEmpty,
              let model = LocalModelCatalog.model(id: modelId),
              fileStore.isModelInstalled(model),
              let nativeGenerator = generator as? NativeMLXGenerator else {
            return
        }

        do {
            if unloadExistingModels {
                await nativeGenerator.unloadAllModels(reason: "preload_reload")
            }
            let modelDirectory = try fileStore.chatRuntimeModelDirectory()
            if let activityCoordinator {
                try await activityCoordinator.withActivity(type: .mlxInference) {
                    try await nativeGenerator.preload(
                        modelId: model.id,
                        modelDirectory: modelDirectory,
                        toolCallFormat: .json
                    )
                }
            } else {
                try await nativeGenerator.preload(
                    modelId: model.id,
                    modelDirectory: modelDirectory,
                    toolCallFormat: .json
                )
            }
        } catch {
            await AppLogger.shared.error(
                category: .localModel,
                message: "preload_failed",
                context: AppLogger.LogCallContext(metadata: [
                    "modelId": model.id,
                    "error": String(describing: error)
                ])
            )
        }
    }

    private func logToolCallingTelemetry(
        modelId: String,
        modelToolCallFormat: ToolCallFormat?,
        toolSpecs: [[String: any Sendable]]?,
        systemContentLength: Int,
        messageCount: Int
    ) async {
        let toolCount = toolSpecs?.count ?? 0
        let formatDesc = modelToolCallFormat?.rawValue ?? "nil"
        var toolNames: [String] = []
        if let tools = toolSpecs, !tools.isEmpty {
            for tool in tools {
                if let function = tool["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    toolNames.append(name)
                }
            }
        }
        await AppLogger.shared.debug(
            category: .localModel,
            message: "tool_calling_request",
            context: AppLogger.LogCallContext(metadata: [
                "modelId": modelId,
                "toolCallFormat": formatDesc,
                "toolCount": toolCount,
                "toolNames": toolNames.joined(separator: ", "),
                "systemPromptLength": systemContentLength,
                "messageCount": messageCount
            ])
        )
    }

    private func logResponseTelemetry(
        modelId: String,
        response: AIServiceResponse,
        toolCount: Int
    ) async {
        let toolCallCount = response.toolCalls?.count ?? 0
        let toolCallNames = (response.toolCalls ?? []).map { "\($0.name)(\($0.arguments.keys.joined(separator: ", ")))" }.joined(separator: "; ")
        let contentPreview = response.content.map { String($0.prefix(200)) } ?? "(empty)"
        let hasTextToolCall = response.content?.lowercased().contains("tool_call") == true || response.content?.lowercased().contains("toolcall") == true
        let hasJsonBlock = response.content?.lowercased().contains("```json") == true

        await AppLogger.shared.debug(
            category: .localModel,
            message: "tool_calling_response",
            context: AppLogger.LogCallContext(metadata: [
                "modelId": modelId,
                "toolCallsGenerated": toolCallCount,
                "toolCallDetails": toolCallNames,
                "toolsWereProvided": toolCount > 0,
                "contentPreview": contentPreview,
                "hasTextToolCallPattern": hasTextToolCall,
                "hasJsonBlock": hasJsonBlock
            ])
        )
    }
}
