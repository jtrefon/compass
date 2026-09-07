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
                let vmFree = ProcessInfo.processInfo.environment["COMPASS_DISABLE_VM_TELEMETRY"] == nil ? "tracked" : "disabled"
                // Structured trace: pressure detail for regression diagnosis
                await AIToolTraceLogger.shared.log(type: "mlx.pressure", data: [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "level": level == .critical ? "critical" : "warning",
                    "generationInFlight": generationInFlight,
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "vmHint": vmFree
                ])
                await AppLogger.shared.warning(
                    category: .localModel,
                    message: "memory_pressure_unload",
                    context: AppLogger.LogCallContext(metadata: [
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "level": level == .critical ? "critical" : "warning",
                        "generationInFlight": String(generationInFlight),
                        "thermalState": String(ProcessInfo.processInfo.thermalState.rawValue)
                    ])
                )
                if Task.isCancelled { return }
                do {
                    try await MLXInferenceLock.shared.acquire()
                    defer { Task { await MLXInferenceLock.shared.release() } }
                    // Unified policy (MemoryPressurePolicy): one home for the
                    // eviction decision. .warning → FIM; .critical → FIM +
                    // buffer cache; .critical + compressor saturated →
                    // also drop the conversation KV (last resort).
                    let compressorPages = await generatorForPressureHandling.currentCompressorPages()
                    let actions = MemoryPressurePolicy.actions(
                        for: level,
                        compressorPages: compressorPages
                    )
                    if actions.contains(.evictFIM) {
                        await InferenceUnloadRegistry.shared.unloadAll(labels: [InferenceUnloadRegistry.fimLabel])
                    }
                    if actions.contains(.releaseBufferCache) {
                        await generatorForPressureHandling.releaseTransientMemory()
                    }
                    if actions.contains(.releaseConversationKV) {
                        await generatorForPressureHandling.releaseConversationKV()
                    }
                } catch {
                    // Cancellation (or a transient wait failure): nothing to
                    // unload safely — the generation that held the lock owns it.
                }
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
        // Ensure exact tokenizer for budget stability: approximate (count+3)/4 vs
        // exact encode caused common 8281 drift between turns.
        await ensureTokenizerLoaded(modelDirectory: modelDirectory)
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
        // NO output cap: local tokens are free — capping (was 1024) truncated
        // whole-file edit calls mid-tool-call and starved the thinking budget
        // (enable_thinking shares the same token pool). The model runs to EOS
        // or the context bounds.
        let safeInferenceConfiguration = model.supportsQuantizedKVCache
            ? inferenceConfiguration
            : inferenceConfiguration.with(kvCache4BitEnabled: false)
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

        let (budgetedMessages, adjustedSystemContent, budgetMessageTokens) = promptBuilder.budgetMessages(
            testBudget.retainedMessages,
            explicitContext: request.context,
            systemContent: systemContent,
            inferenceConfiguration: inferenceConfiguration,
            approximateTokenCount: { [self] in approximateTokenCount($0) }
        )
        // Telemetry reuses the total budgetMessages already computed — the
        // messages are never dropped, so retained == totalBeforeBudget, and
        // re-encoding the full history twice more cost seconds of CPU per send
        // (measured: 3x full-history BPE encode at 41K tokens per turn).
        let retainedTokens = budgetMessageTokens
        let totalBeforeBudget = budgetMessageTokens
        await AIToolTraceLogger.shared.log(type: "mlx.budget", data: [
            "runId": request.runId ?? "",
            "retainedMessages": budgetedMessages.count,
            "retainedTokens": retainedTokens,
            "totalBeforeBudgetTokens": totalBeforeBudget,
            "systemTokens": approximateTokenCount(systemContent),
            "systemTokensAdjusted": approximateTokenCount(adjustedSystemContent),
            "explicitContextTokens": request.context.map { approximateTokenCount($0) } ?? 0,
            "contextLength": inferenceConfiguration.contextLength,
            "maxKVSize": inferenceConfiguration.maxKVSize,
            "headroomTokens": inferenceConfiguration.contextLength - retainedTokens - approximateTokenCount(adjustedSystemContent) - inferenceConfiguration.maxOutputTokens
        ])
        await AIToolTraceLogger.shared.log(type: "mlx.config", data: [
            "runId": request.runId ?? "",
            "modelId": model.id,
            "contextLength": inferenceConfiguration.contextLength,
            "maxKVSize": inferenceConfiguration.maxKVSize,
            "maxOutputTokens": inferenceConfiguration.maxOutputTokens,
            "prefillStepSize": inferenceConfiguration.prefillStepSize,
            "temperature": inferenceConfiguration.temperature,
            "topP": inferenceConfiguration.topP,
            "kvCache4Bit": inferenceConfiguration.kvCache4BitEnabled,
            "cacheKind": inferenceConfiguration.cacheKind
        ])

        // Convert AITool to ToolSpec for MLXLLM
        let toolSpecs = promptBuilder.convertToToolSpec(request.tools)

        // TELEMETRY: Log what we're sending to the model for tool calling diagnosis
        await logToolCallingTelemetry(
            modelId: model.id,
            modelToolCallFormat: .json,
            toolSpecs: toolSpecs,
            systemContentLength: adjustedSystemContent.count,
            messageCount: budgetedMessages.count
        )
        await AIToolTraceLogger.shared.log(type: "mlx.send_message", data: [
            "runId": request.runId ?? "",
            "modelId": model.id,
            "systemPromptChars": adjustedSystemContent.count,
            "systemPromptApproxTokens": approximateTokenCount(adjustedSystemContent),
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
            systemContent: adjustedSystemContent
        )

        // TELEMETRY: Log raw message structure for "what did the model see" diagnosis
        let rawMessageSummary = rawMessages.map { dict -> [String: any Sendable] in
            [
                "role": dict["role"] ?? "",
                "contentLength": (dict["content"] as? String)?.count ?? 0,
                "hasToolCalls": dict["tool_calls"] != nil,
                "toolCallId": dict["tool_call_id"] ?? "",
            ]
        }
        await AIToolTraceLogger.shared.log(type: "mlx.raw_messages", data: [
            "runId": request.runId ?? "",
            "messageCount": rawMessages.count,
            "messages": rawMessageSummary as [any Sendable],
        ])

        // Local inference is text-only (single-model policy) — no media payloads.
        let capturedUserInput = UnsafeValue(value: UserInput(
            messages: rawMessages, images: [], videos: [],
            tools: toolSpecs, additionalContext: additionalContext
        ))
        // Disk-persisted system-prefix cache: new conversations load the
        // pre-computed KV of the system block and prefill only the user
        // message (snappy session/tab startup).
        let prefixCache = makePrefixCacheContext(
            projectRoot: request.projectRoot,
            systemContent: adjustedSystemContent,
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

    /// Memoized per-message token counts. Messages are append-only and
    /// immutable, so a message's count never changes across tool-loop
    /// iterations — re-encoding the whole history with the real BPE tokenizer
    /// on every send cost seconds of CPU per turn at 40K+ tokens (the
    /// "pause between agentic turns"). Keyed by content hash; Swift's Hasher
    /// is stable within a process lifetime, which is all a memo needs.
    /// Reset when it grows past the cap (conversation switch).
    private var tokenCountMemo: [Int: Int] = [:]
    private static let tokenCountMemoCap = 2_048

    private func approximateTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let key = text.hashValue
        if let memoized = tokenCountMemo[key] { return memoized }
        let count: Int
        if let cached = cachedTokenizer {
            count = cached.tokenizer.encode(text: text, addSpecialTokens: false).count
        } else {
            count = max(1, (text.count + 3) / 4)
        }
        if tokenCountMemo.count >= Self.tokenCountMemoCap {
            tokenCountMemo.removeAll()
        }
        tokenCountMemo[key] = count
        return count
    }

    private func ensureTokenizerLoaded(modelDirectory: URL) async {
        if cachedTokenizer != nil { return }
        if let inFlight = tokenizerLoadInFlight {
            if let result = await inFlight.value {
                setCachedTokenizer(result.0, result.1)
            }
            return
        }
        let dir = modelDirectory
        tokenizerLoadInFlight = Task<(URL, any Tokenizers.Tokenizer)?, Never> {
            do {
                let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
                return (dir, tokenizer)
            } catch {
                return nil
            }
        }
        if let result = await tokenizerLoadInFlight?.value {
            setCachedTokenizer(result.0, result.1)
        } else {
            tokenizerLoadInFlight = nil
        }
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
        await generator.unloadAllModels(reason: "offline_mode_disabled")
    }

    private func preloadCurrentModel(unloadExistingModels: Bool) async {
        let model = LocalModelCatalog.chatModel
        guard fileStore.isModelInstalled(model) else { return }

        do {
            if unloadExistingModels {
                await generator.unloadAllModels(reason: "preload_reload")
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
    ///
    /// **Stability guarantee:** every hashed input is byte-identical across
    /// requests with the same system content and tools. The hash changes
    /// ONLY when the rendered system prompt or tool schemas actually change.
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

        // Debug assertion: toolSpecs must be deterministic — two calls with
        // the same inputs produce identical canonical JSON. This catches
        // non-deterministic tool-spec serialization (floating-point rounding,
        // unordered keys in rawMessageValue, etc.) before it causes hash
        // churn mid-session.
#if DEBUG
        if let toolSpecs, let canonical = Self.canonicalJSON(toolSpecs) {
            let second = Self.canonicalJSON(toolSpecs)
            assert(second == canonical, "toolSpecs canonical JSON is not deterministic")
        }
#endif

        var hasher = SHA256()
        hasher.update(data: Data(systemContent.utf8))
        if let toolSpecs,
           let canonicalTools = Self.canonicalJSON(toolSpecs) {
            hasher.update(data: Data(canonicalTools.utf8))
        }
        hasher.update(data: Data(model.id.utf8))
        if let additionalContext, let canonicalCtx = Self.canonicalJSON(additionalContext) {
            hasher.update(data: Data(canonicalCtx.utf8))
        }
        // Context window / maxKVSize intentionally NOT hashed: the cached KV
        // content is independent of them (only quantization and the system
        // prefix shape matter). Including them orphaned the resident cache on
        // every slider change → full re-prefill.
        hasher.update(data: Data("kv4=\(inferenceConfiguration.kvCache4BitEnabled)".utf8))
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

        // Telemetry: log hash inputs so future hash churn can be diagnosed
        // from traces without needing disk files.
        Task { await AIToolTraceLogger.shared.log(type: "mlx.prefix_hash", data: [
            "hash": hash,
            "systemChars": systemContent.count,
            "hasTools": toolSpecs != nil,
            "hasAdditionalContext": additionalContext != nil,
            "kv4Bit": inferenceConfiguration.kvCache4BitEnabled,
            "modelId": model.id
        ]) }

        return PrefixCacheContext(url: url, hash: hash, systemUserInput: systemOnly)
    }

    /// Computes the prefix-cache hash from raw inputs. Exposed as `nonisolated
    /// static` so tests can verify hash stability without instantiating the
    /// full service.
    nonisolated static func computePrefixHash(
        systemContent: String,
        toolSpecs: [[String: any Sendable]]?,
        modelId: String,
        additionalContext: [String: any Sendable]?,
        kv4BitEnabled: Bool
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(systemContent.utf8))
        if let toolSpecs,
           let canonicalTools = Self.canonicalJSON(toolSpecs) {
            hasher.update(data: Data(canonicalTools.utf8))
        }
        hasher.update(data: Data(modelId.utf8))
        if let additionalContext, let canonicalCtx = Self.canonicalJSON(additionalContext) {
            hasher.update(data: Data(canonicalCtx.utf8))
        }
        hasher.update(data: Data("kv4=\(kv4BitEnabled)".utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(32))
    }

    /// Deterministic JSON (recursively sorted keys) so the prefix-cache hash
    /// is stable across requests — JSONSerialization key order is not.
    nonisolated static func canonicalJSON(_ value: Any) -> String? {
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
