import Foundation
import Combine
import CryptoKit
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

actor LocalModelProcessAIService: AIService {
    nonisolated let preservesCache: Bool = true

    typealias MemoryPressureObserverFactory = @Sendable (@escaping @Sendable (MemoryPressureLevel) -> Void) -> (any MemoryPressureObserving)?

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
    private let activityCoordinator: (any AgentActivityCoordinating)?
    private let launchContext: AppLaunchContext
    /// Latest project root (for the KV cache dir when the pressure handler
    /// persists conversation caches before a critical eviction).
    private var lastProjectRoot: URL?
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

        // Tiered memory-pressure policy: .warning releases FIM only (fast to
        // reload; chat + its KV retained); .critical releases everything.
        // Both run behind MLXInferenceLock so an unload can never evict a
        // container under a live generation. Detached task: never inherit the
        // caller's isolation (production fires from a utility queue; unit
        // tests fire from the MainActor).
        self.memoryPressureObserver = memoryPressureObserverFactory { level in
            Task.detached(priority: .utility) {
                let generationInFlight = await generatorForPressureHandling.hasActiveGeneration()
                await AppLogger.shared.warning(
                    category: .localModel,
                    message: "memory_pressure_unload",
                    context: AppLogger.LogCallContext(metadata: [
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "level": level == .critical ? "critical" : "warning",
                        "generationInFlight": String(generationInFlight)
                    ])
                )
                if Task.isCancelled { return }
                do {
                    try await MLXInferenceLock.shared.acquire()
                    defer { Task { await MLXInferenceLock.shared.release() } }
                    switch level {
                    case .warning:
                        await InferenceUnloadRegistry.shared.unloadAll(labels: [InferenceUnloadRegistry.fimLabel])
                    case .critical:
                        await InferenceUnloadRegistry.shared.unloadAll()
                    }
                } catch {
                    // Cancellation (or a transient wait failure): nothing to
                    // unload safely — the generation that held the lock owns it.
                }
            }
        }

        // Chat generator participates in the registry so a single memory-
        // pressure pass unloads every inference container (chat + FIM).
        InferenceUnloadRegistry.shared.register(label: InferenceUnloadRegistry.chatLabel) { [weak self] in
            guard let self else { return }
            let persistDir = await self.lastProjectRoot?
                .appendingPathComponent(".ide", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
            await generatorForPressureHandling.unloadAllModels(
                reason: "memory_pressure", persistKVTo: persistDir)
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
            messages: [ChatMessage(role: .user, content: request.message)],
            context: request.context,
            tools: request.tools,
            mode: request.mode,
            projectRoot: request.projectRoot
        ))
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        // Single-model policy: the chat model is fixed — no selection store.
        let model = LocalModelCatalog.chatModel
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
        let inferenceConfiguration = LocalModelInferenceOverrides.resolve(
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
        let settings = settingsStore.load(includeApiKey: false)
        
        // Build system content for caching
        let systemContent = try promptBuilder.buildSystemContent(
            tools: request.tools,
            mode: request.mode,
            stage: request.stage,
            projectRoot: request.projectRoot,
            settings: settings
        )

        let conversationId = request.conversationId

        let budgetedMessages = promptBuilder.budgetMessages(
            testBudget.retainedMessages,
            explicitContext: request.context,
            systemContent: systemContent,
            inferenceConfiguration: inferenceConfiguration,
            approximateTokenCount: { [self] in approximateTokenCount($0) }
        )

        // Convert AITool to ToolSpec for MLXLLM
        let toolSpecs = promptBuilder.convertToToolSpec(request.tools)

        // TELEMETRY: Log what we're sending to the model for tool calling diagnosis
        await logToolCallingTelemetry(
            modelId: model.id,
            modelToolCallFormat: .json,
            toolSpecs: toolSpecs,
            systemContentLength: systemContent.count,
            messageCount: budgetedMessages.count
        )
        await AIToolTraceLogger.shared.log(type: "mlx.send_message", data: [
            "runId": request.runId ?? "",
            "modelId": model.id,
            "systemPromptChars": systemContent.count,
            "systemPromptApproxTokens": approximateTokenCount(systemContent),
            "messageCount": budgetedMessages.count,
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
            systemContent: systemContent
        )
        // Local inference is text-only (single-model policy) — no media payloads.
        let capturedUserInput = UnsafeValue(value: UserInput(
            messages: rawMessages, images: [], videos: [],
            tools: toolSpecs, additionalContext: additionalContext
        ))
        // Disk-persisted system-prefix cache: new conversations load the
        // pre-computed KV of the system block and prefill only the user
        // message (snappy session/tab startup).
        if let projectRoot = request.projectRoot {
            lastProjectRoot = projectRoot
        }
        let prefixCache = makePrefixCacheContext(
            projectRoot: request.projectRoot,
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            additionalContext: additionalContext,
            inferenceConfiguration: safeInferenceConfiguration,
            model: model
        )

        // Wrap MLX inference with power management to prevent sleep during long generations
        let response: AIServiceResponse
        let capturedGenerator = self.generator
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
                    conversationId: conversationId,
                    prefixCache: prefixCache
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
                conversationId: conversationId,
                prefixCache: prefixCache
            )
        }
        
        // TELEMETRY: Log what we got back from the model
        await logResponseTelemetry(
            modelId: model.id,
            response: response,
            toolCount: toolSpecs?.count ?? 0
        )
        
        return response
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        try await sendMessage(request)
    }

    func preloadSelectedModelIfNeeded() async {
        guard await selectionStore.isOfflineModeEnabled() else { return }
        await preloadCurrentModel(unloadExistingModels: false)
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
        lifecycleObservers = [offlineObserver]
    }

    private func handleOfflineModeChanged(enabled: Bool) async {
        if enabled {
            await preloadCurrentModel(unloadExistingModels: true)
            return
        }
        await generator.unloadAllModels(reason: "offline_mode_disabled", persistKVTo: nil)
    }

    private func preloadCurrentModel(unloadExistingModels: Bool) async {
        let model = LocalModelCatalog.chatModel
        guard fileStore.isModelInstalled(model) else { return }

        do {
            if unloadExistingModels {
                await generator.unloadAllModels(reason: "preload_reload", persistKVTo: nil)
            }
            let modelDirectory = try fileStore.chatRuntimeModelDirectory()
            if let activityCoordinator {
                try await activityCoordinator.withActivity(type: .mlxInference) {
                    try await generator.preload(
                        modelId: model.id,
                        modelDirectory: modelDirectory,
                        toolCallFormat: .json
                    )
                }
            } else {
                try await generator.preload(
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

    /// Builds the disk prefix-cache context (nil when disabled, no project
    /// root, or the system block is empty). The hash covers everything that
    /// shapes the system prefix: prompt text, tool schemas, and KV-affecting
    /// config.
    private func makePrefixCacheContext(
        projectRoot: URL?,
        systemContent: String,
        toolSpecs: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        model: LocalModelDefinition
    ) -> PrefixCacheContext? {
        guard !prefixCacheDisabled else { return nil }
        guard let projectRoot else { return nil }
        guard !systemContent.isEmpty else { return nil }

        var hasher = SHA256()
        hasher.update(data: Data(systemContent.utf8))
        if let toolSpecs,
           let canonicalTools = Self.canonicalJSON(toolSpecs) {
            hasher.update(data: Data(canonicalTools.utf8))
        }
        hasher.update(data: Data(model.id.utf8))
        hasher.update(data: Data("kv4=\(inferenceConfiguration.kvCache4BitEnabled) kv=\(inferenceConfiguration.maxKVSize) ctx=\(inferenceConfiguration.contextLength) pf=\(inferenceConfiguration.prefillStepSize)".utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let hash = String(digest.prefix(32))

        let cacheDir = projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("kv-prefix-\(hash).safetensors")

        // System-only input: same template render (system block + tools
        // section) as a real request, no user message.
        let systemOnly = UserInput(
            messages: [["role": MessageRole.system.rawValue, "content": systemContent]],
            images: [], videos: [],
            tools: toolSpecs,
            additionalContext: additionalContext
        )
        return PrefixCacheContext(url: url, hash: hash, systemUserInput: systemOnly)
    }

    /// Deterministic JSON (recursively sorted keys) so the prefix-cache hash
    /// is stable across requests — JSONSerialization key order is not.
    nonisolated private static func canonicalJSON(_ value: Any) -> String? {
        switch value {
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().compactMap { key -> String? in
                guard let child = canonicalJSON(dict[key] as Any) else { return nil }
                return "\"\(key)\":\(child)"
            }
            return "{\(parts.joined(separator: ","))}"
        case let array as [Any]:
            let parts = array.compactMap { canonicalJSON($0) }
            return "[\("\(parts.joined(separator: ","))")]"
        case let str as String:
            let escaped = str.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case let num as Int:
            return "\"\(num)\"" // strings keep stable bytes
        case let flag as Bool:
            return "\"\(flag)\"" // strings keep stable bytes
        default:
            return "\"\(String(describing: value))\""
        }
    }

    private var prefixCacheDisabled: Bool {
        if ProcessInfo.processInfo.environment["COMPASS_LOCAL_MODEL_DISABLE_PREFIX_CACHE"] == "1" {
            return true
        }
        let profileDir = ProcessInfo.processInfo.environment["COMPASS_TEST_PROFILE_DIR"]
            ?? (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/compass-test-profile-path"),
                encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileDir,
              let conf = try? String(contentsOf: URL(fileURLWithPath: profileDir).appendingPathComponent("local-bench.conf"), encoding: .utf8) else {
            return false
        }
        return conf.split(separator: "\n").contains { $0 == "COMPASS_LOCAL_MODEL_DISABLE_PREFIX_CACHE=1" }
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
