import Foundation
import Combine
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM
import Tokenizers
import Darwin

final class PromptCacheEntry: @unchecked Sendable {
    var cache: [KVCache]?
    var promptTokenIds: [Int] = []
    private let lock = NSLock()

    func set(cache: [KVCache]?, tokenIds: [Int]) {
        lock.lock(); defer { lock.unlock() }
        self.cache = cache
        self.promptTokenIds = tokenIds
    }

    func get() -> (cache: [KVCache]?, tokenIds: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (cache, promptTokenIds)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        promptTokenIds = []
        Memory.clearCache()
    }
}

protocol LocalModelGenerating: Sendable {
    func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat?, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String?) async throws -> AIServiceResponse
}

actor NativeMLXGenerator: LocalModelGenerating {
    private let eventBus: EventBusProtocol
    private var containersByModelDirectory: [URL: ModelContainer] = [:]
    private var inFlightLoads: [URL: Task<ModelContainer, Error>] = [:]
    private var accessOrder: [URL] = []
    private let maxCachedModels = 1
    private var generationCount: Int = 0
    private static let mlxCacheLimitBytes = 128 * 1024 * 1024
    private static let mlxMemoryLimitBytes = 3072 * 1024 * 1024
    private static let defaultTestingRSSLimitMB = 8 * 1024
    private static let defaultOperationalRSSLimitMB = 10 * 1024
    private var promptCacheByConversation: [String: PromptCacheEntry] = [:]
    /// LRU access order for eviction — Dictionary key iteration is hash-based,
    /// so a naive keys.first eviction could drop the ACTIVE conversation's
    /// cache while a stale one stays pinned.
    private var promptCacheAccessOrder: [String] = []
    /// KV caches pin hundreds of MB to GBs of memory per conversation; cap the
    /// retained set so long sessions do not accumulate every conversation's
    /// cache forever.
    private static let maxPromptCacheConversations = 2

    private func promptCacheKey(conversationId: String, modelDirectory: URL) -> String {
        // Keyed by model too — a cross-model KV cache (different layer counts /
        // head dims) would crash with a shape mismatch or silently corrupt output.
        "\(conversationId):\(modelDirectory.standardizedFileURL.path)"
    }

    nonisolated static let sharedTestGenerator: LocalModelGenerating = {
        struct NoOpEventBus: EventBusProtocol {
            func publish<E: Event>(_ event: E) {}
            func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable {
                AnyCancellable {}
            }
        }
        return NativeMLXGenerator(eventBus: NoOpEventBus())
    }()

    init(eventBus: EventBusProtocol) {
        self.eventBus = eventBus
        Memory.cacheLimit = Self.mlxCacheLimitBytes
        Memory.memoryLimit = Self.mlxMemoryLimitBytes
        Task { await Self.logDeviceAndMemoryInfo() }
    }

    nonisolated static func logDeviceAndMemoryInfo() async {
        let defaultDevice = Device.defaultDevice()
        let deviceType = defaultDevice.deviceType?.rawValue ?? "unknown"
        let deviceDesc = String(describing: defaultDevice)
        let gpuInfo = GPU.deviceInfo()
        let gpuArch = gpuInfo.architecture
        let maxWorkingSetMB = Int(gpuInfo.maxRecommendedWorkingSetSize / (1024 * 1024))
        let systemMemMB = gpuInfo.memorySize / (1024 * 1024)
        let cacheLimitMB = Memory.cacheLimit / (1024 * 1024)
        let memoryLimitMB = Memory.memoryLimit / (1024 * 1024)
        await AIToolTraceLogger.shared.log(type: "mlx.device_info", data: [
            "defaultDeviceType": deviceType,
            "deviceDescription": deviceDesc,
            "gpuArchitecture": gpuArch,
            "maxRecommendedWorkingSetMB": maxWorkingSetMB,
            "systemMemoryMB": systemMemMB,
            "mlxCacheLimitMB": cacheLimitMB,
            "mlxMemoryLimitMB": memoryLimitMB
        ])
    }

    deinit {
        Stream().synchronize()
        Memory.clearCache()
    }

    private struct StreamResult {
        var output: String = ""
        var collectedToolCalls: [AIToolCall] = []
        var completionInfo: GenerateCompletionInfo?
        var chunkCount: Int = 0
        var thinkingCharCount: Int = 0
        var executionCharCount: Int = 0
        var thinkingEnded: Bool = false
    }

    func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat? = nil, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String? = nil) async throws -> AIServiceResponse {
        if Task.isCancelled {
            throw CancellationError()
        }
        // Serialize with FIM and other MLX engines — see MLXInferenceLock.
        await MLXInferenceLock.shared.acquire()
        defer { Task { await MLXInferenceLock.shared.release() } }
        logGenerationStart(
            modelId: modelId, modelDirectory: modelDirectory, userInput: userInput,
            tools: tools, toolCallFormat: toolCallFormat, runId: runId,
            inferenceConfiguration: inferenceConfiguration, conversationId: conversationId
        )

        let preparedUserInput = userInput
        let rssLimitMB = Self.resolvedRSSLimitMB()
        let generationStart = ContinuousClock.now

        let parameters = GenerateParameters(
            maxTokens: inferenceConfiguration.maxOutputTokens,
            maxKVSize: inferenceConfiguration.maxKVSize,
            kvBits: inferenceConfiguration.kvCache4BitEnabled ? 4 : nil,
            temperature: inferenceConfiguration.temperature,
            topP: inferenceConfiguration.topP,
            repetitionPenalty: inferenceConfiguration.repetitionPenalty,
            repetitionContextSize: inferenceConfiguration.repetitionContextSize,
            prefillStepSize: inferenceConfiguration.prefillStepSize
        )
        let eventBus = self.eventBus
        let cacheEntry = resolveCacheEntry(conversationId: conversationId, modelDirectory: modelDirectory)

        do {
            let response = try await loadModelAndGenerate(
                modelId: modelId, modelDirectory: modelDirectory, toolCallFormat: toolCallFormat,
                runId: runId, preparedUserInput: preparedUserInput, rssLimitMB: rssLimitMB,
                generationStart: generationStart, parameters: parameters, eventBus: eventBus,
                cacheEntry: cacheEntry, inferenceConfiguration: inferenceConfiguration
            )

            generationCount += 1
            logMLXMemorySnapshot()
            if Self.shouldUnloadModelAfterGeneration() {
                unloadModel(modelDirectory: modelDirectory, reason: "post_generation_env_flag")
            }

            return response
        } catch {
            // Keep the container on cancellation and transient stream errors —
            // unloading here meant pressing Stop cost a full ~2.5GB reload and
            // dropped every conversation's KV cache. Only load-time/RSS
            // failures and explicit unload requests should tear it down.
            if !(error is CancellationError) && !Task.isCancelled {
                unloadModel(modelDirectory: modelDirectory, reason: "generation_error")
            }
            throw error
        }
    }

    private func logGenerationStart(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat? = nil, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String? = nil) {
        let mlxStream = String(describing: StreamOrDevice.default)
        let defaultDevice = Device.defaultDevice()
        let deviceType = defaultDevice.deviceType?.rawValue ?? "unknown"
        let messageCount: Int
        switch userInput.prompt {
        case .messages(let msgs): messageCount = msgs.count
        case .chat(let msgs): messageCount = msgs.count
        case .text: messageCount = 1
        }
        let toolCount = tools?.count ?? 0
        Task {
            await AIToolTraceLogger.shared.log(type: "mlx.generate_start", data: [
                "runId": runId ?? "",
                "modelId": modelId,
                "deviceType": deviceType,
                "contextLength": inferenceConfiguration.contextLength,
                "maxKVSize": inferenceConfiguration.maxKVSize,
                "maxOutputTokens": inferenceConfiguration.maxOutputTokens,
                "prefillStepSize": inferenceConfiguration.prefillStepSize,
                "temperature": inferenceConfiguration.temperature,
                "topP": inferenceConfiguration.topP,
                "kvCache4Bit": inferenceConfiguration.kvCache4BitEnabled,
                "cacheKind": inferenceConfiguration.cacheKind,
                "messageCount": messageCount,
                "toolCount": toolCount,
                "conversationId": conversationId ?? ""
            ])
        }
    }

    private func resolveCacheEntry(conversationId: String?, modelDirectory: URL) -> PromptCacheEntry? {
        guard let conversationId else { return nil }
        let key = promptCacheKey(conversationId: conversationId, modelDirectory: modelDirectory)
        if let existing = promptCacheByConversation[key] {
            // touch for LRU
            promptCacheAccessOrder.removeAll { $0 == key }
            promptCacheAccessOrder.append(key)
            return existing
        }
        if promptCacheByConversation.count >= Self.maxPromptCacheConversations,
           let evictKey = promptCacheAccessOrder.first {
            promptCacheAccessOrder.removeFirst()
            promptCacheByConversation.removeValue(forKey: evictKey)
        }
        let entry = PromptCacheEntry()
        promptCacheByConversation[key] = entry
        promptCacheAccessOrder.append(key)
        return entry
    }

    private func loadModelAndGenerate(
        modelId: String,
        modelDirectory: URL,
        toolCallFormat: ToolCallFormat?,
        runId: String?,
        preparedUserInput: UserInput,
        rssLimitMB: Int,
        generationStart: ContinuousClock.Instant,
        parameters: GenerateParameters,
        eventBus: EventBusProtocol,
        cacheEntry: PromptCacheEntry?,
        inferenceConfiguration: LocalModelInferenceConfiguration
    ) async throws -> AIServiceResponse {
        let defaultDevice = Device.defaultDevice()
        let deviceType = defaultDevice.deviceType?.rawValue ?? "unknown"
        try Self.throwIfProcessRSSExceeded(limitMB: rssLimitMB, phase: "before_container_load")
        let rssBeforeLoadMB = Self.currentProcessRSSMB()
        let loadStart = ContinuousClock.now
        let container = try await loadContainerCached(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
        let loadDuration = loadStart.duration(to: ContinuousClock.now)
        let rssAfterLoadMB = Self.currentProcessRSSMB()
        try Self.throwIfProcessRSSExceeded(limitMB: rssLimitMB, phase: "after_container_load")
        let mlxActiveAfterLoad = MLX.Memory.activeMemory / (1024 * 1024)
        let mlxPeakAfterLoad = MLX.Memory.peakMemory / (1024 * 1024)
        await AIToolTraceLogger.shared.log(type: "mlx.model_loaded", data: [
            "runId": runId ?? "",
            "modelId": modelId,
            "loadMs": Self.milliseconds(loadDuration),
            "rssBeforeLoadMB": rssBeforeLoadMB,
            "rssAfterLoadMB": rssAfterLoadMB
        ])
        let capturedInput = UnsafeValue(value: preparedUserInput)
        return try await container.perform { context in
            try Self.throwIfProcessRSSExceeded(limitMB: rssLimitMB, phase: "before_generation")

            let input = try await context.processor.prepare(input: capturedInput.value)
            let promptTokenCount = input.text.tokens.size
            let promptTokenIds = input.text.tokens.asArray(Int.self)
            await AIToolTraceLogger.shared.log(type: "mlx.prompt_prepared", data: [
                "runId": runId ?? "",
                "modelId": modelId,
                "promptTokens": promptTokenCount
            ])

            let (kvCache, effectiveInput) = try self.resolveKVCache(
                input: input,
                from: cacheEntry,
                promptTokenIds: promptTokenIds,
                parameters: parameters,
                context: context
            )

            let rssBeforeGen = Self.currentProcessRSSMB()
            let mlxActiveBeforeGen = MLX.Memory.activeMemory / (1024 * 1024)
            let mlxPeakBeforeGen = MLX.Memory.peakMemory / (1024 * 1024)
            let effectiveTokenCount = effectiveInput.text.tokens.size
            MLX.Memory.peakMemory = 0
            let genStart = ContinuousClock.now
            let streamResult = try await self.processGeneration(
                input: effectiveInput,
                kvCache: kvCache,
                parameters: parameters,
                context: context,
                runId: runId,
                eventBus: eventBus,
                rssLimitMB: rssLimitMB,
                genStart: genStart,
                modelId: modelId
            )

            if let cacheEntry, let kvCache, !kvCache.isEmpty {
                let generatedIds = streamResult.completionInfo?.generatedTokenIds ?? []
                let fullTokenIds = promptTokenIds + generatedIds
                cacheEntry.set(cache: kvCache, tokenIds: fullTokenIds)
            }

            return await self.buildGenerationResponse(
                streamResult: streamResult,
                promptTokenCount: promptTokenCount,
                generationStart: generationStart,
                loadDuration: loadDuration,
                modelId: modelId,
                inferenceConfiguration: inferenceConfiguration,
                rssBeforeLoadMB: rssBeforeLoadMB,
                rssAfterLoadMB: rssAfterLoadMB,
                deviceType: deviceType,
                runId: runId
            )
        }
    }

    private nonisolated func resolveKVCache(
        input: LMInput,
        from cacheEntry: PromptCacheEntry?,
        promptTokenIds: [Int],
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> (kvCache: [KVCache]?, effectiveInput: LMInput) {
        var effectiveInput = input
        var kvCache: [KVCache]? = nil

        // H11: media turns drop the image/video payloads on the reused path
        // (the suffix input is text-only) — never reuse a KV cache for
        // multimodal turns.
        if input.image != nil || input.video != nil {
            return (nil, input)
        }

        let (cachedCache, cachedTokenIds) = cacheEntry?.get() ?? (nil, [])
        if let cachedCache, !cachedCache.isEmpty, !cachedTokenIds.isEmpty, !promptTokenIds.isEmpty {
            let commonLen = Self.commonPrefixLength(cachedTokenIds, promptTokenIds)
            let trimCount = cachedTokenIds.count - commonLen

            if commonLen > 0 {
                var reuseCache: [KVCache] = []
                var skipReuse = false
                for cache in cachedCache {
                    if let maxSize = cache.maxSize, cache.offset > maxSize {
                        skipReuse = true
                        break
                    }
                    if trimCount > 0 {
                        _ = cache.trim(trimCount)
                    }
                    reuseCache.append(cache)
                }

                if !skipReuse, commonLen < promptTokenIds.count {
                    let suffixTokens = Array(promptTokenIds[commonLen...])
                    let suffixArray = MLXArray(suffixTokens).expandedDimensions(axis: 0)
                    effectiveInput = LMInput(text: LMInput.Text(tokens: suffixArray), image: nil, video: nil)
                    kvCache = reuseCache
                } else if !skipReuse, commonLen == promptTokenIds.count {
                    // Exact-prefix case: the cache already holds ALL prompt
                    // tokens (plus stale generations). Re-prefilling the full
                    // prompt onto it attends twice and continues from the stale
                    // answer — drop reuse and prefill fresh.
                    kvCache = nil
                }
            }
        }

        if kvCache == nil {
            if let cacheEntry {
                cacheEntry.clear()
            }
            kvCache = context.model.newCache(parameters: parameters)
        }

        return (kvCache, effectiveInput)
    }

    private nonisolated func processGeneration(
        input: LMInput,
        kvCache: [KVCache]?,
        parameters: GenerateParameters,
        context: ModelContext,
        runId: String?,
        eventBus: EventBusProtocol,
        rssLimitMB: Int,
        genStart: ContinuousClock.Instant,
        modelId: String
    ) async throws -> StreamResult {
        let stream = try MLXLMCommon.generate(
            input: input,
            cache: kvCache,
            parameters: parameters,
            context: context
        )
        var result = StreamResult()
        var isInThinking = false

        func publishStatus(_ message: String) {
            guard let runId else { return }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            eventBus.publish(LocalModelStreamingStatusEvent(runId: runId, message: message))
        }

        for await generation in stream {
            if Task.isCancelled {
                throw CancellationError()
            }
            if result.chunkCount % 50 == 0 {
                try Self.throwIfProcessRSSExceeded(limitMB: rssLimitMB, phase: "streaming")
            }
            result.chunkCount += 1
            if result.chunkCount == 1 {
                let prefillMs = Self.milliseconds(genStart.duration(to: ContinuousClock.now))
                let rssAfterPrefill = Self.currentProcessRSSMB()
                let mlxActiveAfterPrefill = MLX.Memory.activeMemory / (1024 * 1024)
                let mlxPeakAfterPrefill = MLX.Memory.peakMemory / (1024 * 1024)
                await AIToolTraceLogger.shared.log(type: "mlx.first_token", data: [
                    "runId": runId ?? "",
                    "modelId": modelId,
                    "prefillMs": prefillMs,
                    "promptTokens": result.chunkCount,
                    "promptTokensPerSecond": result.chunkCount > 0 ? Double(result.chunkCount) / (Double(prefillMs) / 1000.0) : 0
                ])
            }
            if result.chunkCount % 50 == 0 {
                let elapsedMs = Self.milliseconds(genStart.duration(to: ContinuousClock.now))
            }

            switch generation {
            case .chunk(let text):
                if text.contains("<think>") {
                    isInThinking = true
                }
                if text.contains("</think>") {
                    isInThinking = false
                    result.thinkingEnded = true
                }
                if isInThinking {
                    result.thinkingCharCount += text.count
                } else {
                    result.executionCharCount += text.count
                }
                result.output.append(text)
                if let runId, !text.isEmpty {
                    // Always publish the first chunk (short completions may
                    // otherwise never stream), then throttle to every 8th.
                    if result.chunkCount == 1 || result.chunkCount % 8 == 0 {
                        eventBus.publish(LocalModelStreamingChunkEvent(runId: runId, chunk: text))
                    }
                }
            case .info:
                if case .info(let info) = generation {
                    result.completionInfo = info
                }
            case .toolCall(let toolCall):
                result.collectedToolCalls.append(Self.makeAIToolCall(from: toolCall))
                publishStatus("Structured tool call detected: \(toolCall.function.name)")
            }
        }

        return result
    }

    private nonisolated func buildGenerationResponse(
        streamResult: StreamResult,
        promptTokenCount: Int,
        generationStart: ContinuousClock.Instant,
        loadDuration: Duration,
        modelId: String,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        rssBeforeLoadMB: Int,
        rssAfterLoadMB: Int,
        deviceType: String,
        runId: String?
    ) async -> AIServiceResponse {
        let trimmedOutput = streamResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalDuration = generationStart.duration(to: ContinuousClock.now)
        let totalMs = Self.milliseconds(totalDuration)
        let genMs: Int
        let genTokens: Int
        let genTps: Double
        let promptMs: Int
        let promptTokens: Int
        let promptTps: Double
        if let info = streamResult.completionInfo {
            promptMs = Int((info.promptTime * 1000).rounded())
            promptTokens = info.promptTokenCount
            promptTps = info.promptTokensPerSecond
            genMs = Int((info.generateTime * 1000).rounded())
            genTokens = info.generationTokenCount
            genTps = info.tokensPerSecond
        } else {
            promptMs = 0
            promptTokens = promptTokenCount
            promptTps = 0
            genMs = totalMs - Self.milliseconds(loadDuration)
            genTokens = streamResult.chunkCount
            genTps = 0
        }
        await AIToolTraceLogger.shared.log(type: "mlx.generate_complete", data: [
            "runId": runId ?? "",
            "modelId": modelId,
            "deviceType": deviceType,
            "loadMs": Self.milliseconds(loadDuration),
            "promptMs": promptMs,
            "promptTokens": promptTokens,
            "promptTokensPerSecond": promptTps,
            "generationMs": genMs,
            "generationTokens": genTokens,
            "generationTokensPerSecond": genTps,
            "totalMs": totalMs,
            "outputChars": trimmedOutput.count,
            "toolCalls": streamResult.collectedToolCalls.count,
            "chunkCount": streamResult.chunkCount,
            "rssBeforeLoadMB": rssBeforeLoadMB,
            "rssAfterLoadMB": rssAfterLoadMB,
            "rssAfterGenMB": Self.currentProcessRSSMB(),
            "contextLength": inferenceConfiguration.contextLength,
            "maxKVSize": inferenceConfiguration.maxKVSize,
            "maxOutputTokens": inferenceConfiguration.maxOutputTokens,
            "kvCache4Bit": inferenceConfiguration.kvCache4BitEnabled,
            "cacheKind": inferenceConfiguration.cacheKind,
            "hasCompletionInfo": streamResult.completionInfo != nil
        ])
        let approxThinkingTokens = max(0, streamResult.thinkingCharCount) / 4
        let approxExecutionTokens = max(0, streamResult.executionCharCount) / 4
        Self.logGenerationPerformance(
            modelId: modelId,
            inferenceConfiguration: inferenceConfiguration,
            loadDuration: loadDuration,
            totalDuration: totalDuration,
            completionInfo: streamResult.completionInfo,
            outputCharacterCount: trimmedOutput.count,
            toolCallCount: streamResult.collectedToolCalls.count,
            rssBeforeLoadMB: rssBeforeLoadMB,
            rssAfterLoadMB: rssAfterLoadMB,
            rssAfterGenerationMB: Self.currentProcessRSSMB()
        )
        let toolCalls: [AIToolCall]? = streamResult.collectedToolCalls.isEmpty ? nil : streamResult.collectedToolCalls
        return AIServiceResponse(
            content: trimmedOutput.isEmpty ? nil : trimmedOutput,
            toolCalls: toolCalls
        )
    }

    func preload(modelId: String, modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws {
        let loadStart = ContinuousClock.now
        _ = try await loadContainerCached(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
        let loadDuration = loadStart.duration(to: ContinuousClock.now)
    }

    private func synchronizeMLXStream() {
        Stream().synchronize()
    }

    private func logMLXMemorySnapshot() {
        let snapshot = Memory.snapshot()
        let activeMB = snapshot.activeMemory / (1024 * 1024)
        let cacheMB = snapshot.cacheMemory / (1024 * 1024)
        let peakMB = snapshot.peakMemory / (1024 * 1024)
        Task {
            await AIToolTraceLogger.shared.log(type: "mlx.memory_snapshot", data: [
                "generationCount": generationCount,
                "activeMB": activeMB,
                "cacheMB": cacheMB,
                "peakMB": peakMB
            ])
        }
    }

    nonisolated private static func resolvedRSSLimitMB() -> Int {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["COMPASS_LOCAL_MODEL_MAX_RSS_MB"],
           let parsed = Int(configured),
           parsed > 0 {
            return parsed
        }

        return AppRuntimeEnvironment.launchContext.isTesting
            ? defaultTestingRSSLimitMB
            : defaultOperationalRSSLimitMB
    }

    nonisolated private static func shouldUnloadModelAfterGeneration() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["COMPASS_LOCAL_MODEL_UNLOAD_AFTER_GENERATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            switch configured {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                break
            }
        }

        return false
    }

    nonisolated private static func logGenerationPerformance(
        modelId: String,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        loadDuration: Duration,
        totalDuration: Duration,
        completionInfo: GenerateCompletionInfo?,
        outputCharacterCount: Int,
        toolCallCount: Int,
        rssBeforeLoadMB: Int,
        rssAfterLoadMB: Int,
        rssAfterGenerationMB: Int
    ) {
        let loadMS = milliseconds(loadDuration)
        let totalMS = milliseconds(totalDuration)
        let snapshot: LocalModelGenerationPerformanceSnapshot
        if let info = completionInfo {
            let promptMS = Int((info.promptTime * 1000).rounded())
            let generateMS = Int((info.generateTime * 1000).rounded())
            snapshot = LocalModelGenerationPerformanceSnapshot(
                modelId: modelId,
                inferenceConfiguration: inferenceConfiguration,
                loadMilliseconds: loadMS,
                totalMilliseconds: totalMS,
                promptTokenCount: info.promptTokenCount,
                promptMilliseconds: promptMS,
                promptTokensPerSecond: info.promptTokensPerSecond,
                generationTokenCount: info.generationTokenCount,
                generationMilliseconds: generateMS,
                generationTokensPerSecond: info.tokensPerSecond,
                toolCallCount: toolCallCount,
                outputCharacterCount: outputCharacterCount,
                rssBeforeLoadMB: rssBeforeLoadMB,
                rssAfterLoadMB: rssAfterLoadMB,
                rssAfterGenerationMB: rssAfterGenerationMB,
                timestamp: Date()
            )
        } else {
            snapshot = LocalModelGenerationPerformanceSnapshot(
                modelId: modelId,
                inferenceConfiguration: inferenceConfiguration,
                loadMilliseconds: loadMS,
                totalMilliseconds: totalMS,
                promptTokenCount: nil,
                promptMilliseconds: nil,
                promptTokensPerSecond: nil,
                generationTokenCount: nil,
                generationMilliseconds: nil,
                generationTokensPerSecond: nil,
                toolCallCount: toolCallCount,
                outputCharacterCount: outputCharacterCount,
                rssBeforeLoadMB: rssBeforeLoadMB,
                rssAfterLoadMB: rssAfterLoadMB,
                rssAfterGenerationMB: rssAfterGenerationMB,
                timestamp: Date()
            )
        }

        Task {
            await LocalModelGenerationPerformanceRecorder.shared.record(snapshot)
        }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000) + (Double(duration.components.attoseconds) / 1_000_000_000_000_000))
    }

    nonisolated private static func throwIfProcessRSSExceeded(limitMB: Int, phase: String) throws {
        let rssMB = currentProcessRSSMB()
        guard rssMB < limitMB else {
            throw AppError.aiServiceError(
                "Local model memory budget exceeded during \(phase): \(rssMB)MB used with limit \(limitMB)MB"
            )
        }
    }

    nonisolated private static func currentProcessRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    nonisolated private static func makeAIToolCall(from toolCall: ToolCall) -> AIToolCall {
        let rawArgs = toolCall.function.arguments.mapValues { $0.anyValue }
        let arguments: [String: Any] = rawArgs.mapValues { value in
            guard var str = value as? String else { return value }
            str = str.replacingOccurrences(of: "<|\"|>", with: "")
            return str
        }
        return AIToolCall(
            id: UUID().uuidString,
            name: toolCall.function.name,
            arguments: arguments
        )
    }

    nonisolated static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] != b[i] { return i }
        }
        return minLen
    }

    nonisolated static func extractGemmaToolCalls(from content: String) -> [AIToolCall]? {
        let calls = parseGemmaToolCalls(from: content)
        guard !calls.isEmpty else { return nil }
        return calls
    }

    nonisolated static func parseGemmaToolCalls(from content: String) -> [AIToolCall] {
        let marker = "call:"
        var results: [AIToolCall] = []
        var searchStart = content.startIndex

        while let markerRange = content.range(of: marker, range: searchStart..<content.endIndex) {
            let afterMarker = markerRange.upperBound

            var nameEnd = afterMarker
            while nameEnd < content.endIndex, content[nameEnd].isLetter || content[nameEnd].isNumber || content[nameEnd] == "_" {
                nameEnd = content.index(after: nameEnd)
            }
            guard nameEnd > afterMarker else {
                searchStart = markerRange.upperBound
                continue
            }
            let name = String(content[afterMarker..<nameEnd])

            var braceStart = nameEnd
            while braceStart < content.endIndex, content[braceStart].isWhitespace {
                braceStart = content.index(after: braceStart)
            }
            guard braceStart < content.endIndex, content[braceStart] == "{" else {
                searchStart = nameEnd
                continue
            }

            var depth = 1
            var pos = content.index(after: braceStart)
            while pos < content.endIndex && depth > 0 {
                let ch = content[pos]
                if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1 }
                if depth > 0 {
                    pos = content.index(after: pos)
                }
            }
            guard depth == 0 else {
                searchStart = nameEnd
                continue
            }
            let argsText = String(content[content.index(after: braceStart)..<pos])

            let cleanedArgs = argsText.replacingOccurrences(of: "<|\"|>", with: "\"")

            let jsonText = "{\(cleanedArgs)}"
            var arguments: [String: Any] = [:]
            if let jsonData = jsonText.data(using: .utf8),
               let jsonObj = try? JSONSerialization.jsonObject(with: jsonData),
               let argsDict = jsonObj as? [String: Any] {
                arguments = argsDict
            } else {
                var fallbackArgs: [String: String] = [:]
                let stripped = cleanedArgs.replacingOccurrences(of: "\"", with: "")
                let pairPattern = #"(\w+):(.*?)(?:,\s*\w+|$)"#
                if let pairRegex = try? NSRegularExpression(pattern: pairPattern, options: [.dotMatchesLineSeparators]) {
                    let pairRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
                    let pairMatches = pairRegex.matches(in: stripped, options: [], range: pairRange)
                    for pair in pairMatches {
                        guard pair.numberOfRanges >= 3,
                              let keyRange = Range(pair.range(at: 1), in: stripped),
                              let valRange = Range(pair.range(at: 2), in: stripped) else { continue }
                        let key = String(stripped[keyRange])
                        let val = String(stripped[valRange]).trimmingCharacters(in: .whitespaces)
                        fallbackArgs[key] = val
                    }
                }
                arguments = fallbackArgs
            }

            results.append(AIToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            ))

            searchStart = content.index(after: pos)
        }

        return results
    }

    nonisolated static func extractFallbackToolCalls(
        from content: String,
        toolsWereProvided: Bool,
        structuredToolCallsWereDetected: Bool,
        toolCallFormat: ToolCallFormat?
    ) -> [AIToolCall]? {
        guard toolsWereProvided, !structuredToolCallsWereDetected else { return nil }
        guard !content.isEmpty else { return nil }

        if let directCall = decodeFallbackToolCall(from: content) {
            return [directCall]
        }

        if let wrappedCalls = decodeFallbackToolCallsEnvelope(from: content), !wrappedCalls.isEmpty {
            return wrappedCalls
        }

        if let fencedJSON = extractFirstJSONCodeBlock(from: content) {
            if let directCall = decodeFallbackToolCall(from: fencedJSON) {
                return [directCall]
            }
            if let wrappedCalls = decodeFallbackToolCallsEnvelope(from: fencedJSON), !wrappedCalls.isEmpty {
                return wrappedCalls
            }
        }

        return nil
    }

    nonisolated private static func regexMatches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    nonisolated private static func regexCaptureGroups(in text: String, pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).map { match in
            guard match.numberOfRanges > 1 else { return [] }
            return (1..<match.numberOfRanges).compactMap { index in
                let groupRange = match.range(at: index)
                guard groupRange.location != NSNotFound,
                      let swiftRange = Range(groupRange, in: text) else {
                    return nil
                }
                return String(text[swiftRange])
            }
        }
    }

    nonisolated private static func decodeFallbackToolCall(from raw: String) -> AIToolCall? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AIToolCall.self, from: data) else {
            return nil
        }
        return decoded
    }

    nonisolated private static func decodeFallbackToolCallsEnvelope(from raw: String) -> [AIToolCall]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawToolCalls = object["tool_calls"] as? [[String: Any]] else {
            return nil
        }

        let decodedToolCalls = rawToolCalls.compactMap { rawCall -> AIToolCall? in
            guard JSONSerialization.isValidJSONObject(rawCall),
                  let callData = try? JSONSerialization.data(withJSONObject: rawCall),
                  let call = try? JSONDecoder().decode(AIToolCall.self, from: callData) else {
                return nil
            }
            return call
        }
        return decodedToolCalls.isEmpty ? nil : decodedToolCalls
    }

    nonisolated private static func extractFirstJSONCodeBlock(from content: String) -> String? {
        guard let openingRange = content.range(of: "```json") ?? content.range(of: "```") else {
            return nil
        }
        let remainder = content[openingRange.upperBound...]
        guard let closingRange = remainder.range(of: "```") else {
            return nil
        }
        return remainder[..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadAllModels(reason: String = "unknown") {
        synchronizeMLXStream()
        containersByModelDirectory.removeAll()
        inFlightLoads.removeAll()
        accessOrder.removeAll()
        Memory.clearCache()
    }

    func unloadModel(modelDirectory: URL, reason: String = "unknown") {
        synchronizeMLXStream()
        let cacheKey = modelDirectory.resolvingSymlinksInPath().standardizedFileURL
        containersByModelDirectory.removeValue(forKey: cacheKey)
        inFlightLoads.removeValue(forKey: cacheKey)
        accessOrder.removeAll { $0 == cacheKey }
        promptCacheByConversation.removeAll()
        Memory.clearCache()
    }

    private func loadContainerCached(modelDirectory: URL, toolCallFormat: ToolCallFormat? = nil) async throws -> ModelContainer {
        let cacheKey = modelDirectory.resolvingSymlinksInPath().standardizedFileURL

        if let existing = containersByModelDirectory[cacheKey] {
            accessOrder.removeAll { $0 == cacheKey }
            accessOrder.append(cacheKey)
            return existing
        }

        if let existingTask = inFlightLoads[cacheKey] {
            return try await existingTask.value
        }

        if containersByModelDirectory.count >= maxCachedModels, let oldest = accessOrder.first {
            containersByModelDirectory.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        let configuration = ModelConfiguration(directory: cacheKey, toolCallFormat: toolCallFormat)
        let loadTask = Task<ModelContainer, Error> {
            try await self.loadModelContainer(
                configuration: configuration,
                modelDirectory: cacheKey
            )
        }
        inFlightLoads[cacheKey] = loadTask

        let container: ModelContainer
        do {
            container = try await loadTask.value
        } catch {
            inFlightLoads.removeValue(forKey: cacheKey)
            throw error
        }

        inFlightLoads.removeValue(forKey: cacheKey)
        containersByModelDirectory[cacheKey] = container
        accessOrder.append(cacheKey)
        return container
    }

    private func loadModelContainer(
        configuration _: ModelConfiguration,
        modelDirectory: URL
    ) async throws -> ModelContainer {
        struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
            let directory: URL
            func load(from _: URL) async throws -> any MLXLMCommon.Tokenizer {
                let upstream = try await AutoTokenizer.from(modelFolder: directory)
                struct Bridge: MLXLMCommon.Tokenizer {
                    let upstream: any Tokenizers.Tokenizer
                    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
                        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
                    }
                    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
                        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
                    }
                    func convertTokenToId(_ token: String) -> Int? {
                        upstream.convertTokenToId(token)
                    }
                    func convertIdToToken(_ id: Int) -> String? {
                        upstream.convertIdToToken(id)
                    }
                    var bosToken: String? { upstream.bosToken }
                    var eosToken: String? { upstream.eosToken }
                    var unknownToken: String? { upstream.unknownToken }
                    func applyChatTemplate(
                        messages: [[String: any Sendable]],
                        tools: [[String: any Sendable]]?,
                        additionalContext: [String: any Sendable]?
                    ) throws -> [Int] {
                        do {
                            return try upstream.applyChatTemplate(
                                messages: messages, tools: tools,
                                additionalContext: additionalContext)
                        } catch Tokenizers.TokenizerError.missingChatTemplate {
                            throw MLXLMCommon.TokenizerError.missingChatTemplate
                        }
                    }
                }
                return Bridge(upstream: upstream)
            }
        }
        let tokenizerLoader = LocalTokenizerLoader(directory: modelDirectory)
        // Fixed chat model (Qwen3.5-4B) is text-only — always the LLM factory.
        return try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory, using: tokenizerLoader)
    }
}
