import Foundation
import Combine
import CryptoKit
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM
import Tokenizers
import Darwin

final class PromptCacheEntry: @unchecked Sendable {
    var cache: [KVCache]?
    var promptTokenIds: [Int] = []
    /// System-prefix hash the cache was seeded/validated against (for
    /// conversation-level disk persistence).
    var systemHash: String?
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
    func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat?, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String?, prefixCache: PrefixCacheContext?) async throws -> AIServiceResponse
    func preload(modelId: String, modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws
    func unloadAllModels(reason: String, persistKVTo: URL?) async
    func hasActiveGeneration() async -> Bool
}

/// Disk-persisted system-prefix KV cache: built once per (project, settings),
/// loaded into new conversations so only the user message prefills.
struct PrefixCacheContext: Sendable {
    let url: URL
    let hash: String
    /// System-only input (renders the same system block + tools section as a
    /// real request, with no user message) used to build the prefix cache.
    let systemUserInput: UserInput
}

actor NativeMLXGenerator: LocalModelGenerating {
    private let eventBus: EventBusProtocol
    private var containersByModelDirectory: [URL: ModelContainer] = [:]
    private var inFlightLoads: [URL: Task<ModelContainer, Error>] = [:]
    private var accessOrder: [URL] = []
    private let maxCachedModels = 1
    private var generationCount: Int = 0
    /// Generations currently executing; the unload path waits for these
    /// (defense in depth — the pressure handler already holds
    /// MLXInferenceLock, this guards the non-locked unload callers).
    private var activeGenerationCount = 0
    private static let mlxCacheLimitBytes = 1024 * 1024 * 1024
    private static let defaultTestingRSSLimitMB = 8 * 1024
    private static let defaultOperationalRSSLimitMB = 10 * 1024
    private var promptCacheByConversation: [String: PromptCacheEntry] = [:]
    private var savedPrefixCacheHashes: Set<String> = []
    /// LRU access order for eviction — Dictionary key iteration is hash-based,
    /// so a naive keys.first eviction could drop the ACTIVE conversation's
    /// cache while a stale one stays pinned.
    private var promptCacheAccessOrder: [String] = []
    /// KV caches pin hundreds of MB to GBs of memory per conversation; cap the
    /// retained set so long sessions do not accumulate every conversation's
    /// cache forever.
    private static let maxPromptCacheConversations = 1

    private func promptCacheKey(conversationId: String, modelDirectory: URL) -> String {
        // Keyed by model too — a cross-model KV cache (different layer counts /
        // head dims) would crash with a shape mismatch or silently corrupt output.
        "\(conversationId):\(modelDirectory.standardizedFileURL.path)"
    }

    nonisolated static let sharedTestGenerator: LocalModelGenerating = {
        NativeMLXGenerator(eventBus: NoOpEventBus())
    }()

    private let memoryMonitor: any EngineMemoryMonitoring

    init(
        eventBus: EventBusProtocol,
        memoryMonitor: any EngineMemoryMonitoring = ProcessMemoryMonitor()
    ) {
        self.eventBus = eventBus
        self.memoryMonitor = memoryMonitor
        // Memory budget: do NOT clamp mlx's memoryLimit to a tiny hard cap —
        // malloc then blocks on every allocation over it (a 2.5GB model under
        // a 3GB limit made prefill/generation wait on scheduled tasks, ~4-10x
        // slower). Default = 1.5x the device's recommended working set, which
        // is right for a 15GB M-series. Cache limit: 1GB (was 128MB — every
        // eval flushed and re-allocated Metal buffers). Both knobs stay
        // tunable for the benchmark (COMPASS_LOCAL_MODEL_* conf transport).
        Memory.cacheLimit = Self.mlxCacheLimitBytes
        if let configured = ProcessInfo.processInfo.environment["COMPASS_LOCAL_MODEL_MLX_MEMORY_LIMIT_MB"],
           let limitMB = Int(configured), limitMB > 0 {
            Memory.memoryLimit = limitMB * 1024 * 1024
        }
        let monitorCopy = memoryMonitor
        Task { await monitorCopy.logDeviceInfo() }
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
        /// Exact token IDs sampled during this generation (in cache order) —
        /// used for KV-reuse bookkeeping. NEVER re-derive these from the
        /// emitted text: tokenization is not round-trip stable.
        var generatedTokenIds: [Int] = []
    }

    func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat? = nil, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String? = nil, prefixCache: PrefixCacheContext? = nil) async throws -> AIServiceResponse {
        if Task.isCancelled {
            throw CancellationError()
        }
        // Serialize with FIM and other MLX engines — see MLXInferenceLock.
        try await MLXInferenceLock.shared.acquire()
        try Task.checkCancellation()
        // Chat/agent work has foreground priority. FIM is useful while the
        // editor is idle, but retaining its weights alongside Qwen consumes a
        // large portion of unified memory for no concurrent benefit. Holding
        // the shared lock means an active FIM stream has finished before its
        // container is released.
        await InferenceUnloadRegistry.shared.unloadAll(labels: [InferenceUnloadRegistry.fimLabel])
        activeGenerationCount += 1
        defer {
            activeGenerationCount -= 1
            Task { await MLXInferenceLock.shared.release() }
        }
        logGenerationStart(
            modelId: modelId, modelDirectory: modelDirectory, userInput: userInput,
            tools: tools, toolCallFormat: toolCallFormat, runId: runId,
            inferenceConfiguration: inferenceConfiguration, conversationId: conversationId
        )

        let preparedUserInput = userInput
        let rssLimitMB = memoryMonitor.resolvedLimitMB()
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
        let cacheEntry = resolveCacheEntry(
            conversationId: conversationId,
            modelDirectory: modelDirectory,
            prefixCache: prefixCache,
            inferenceConfiguration: inferenceConfiguration
        )

        do {
            let response = try await loadModelAndGenerate(
                modelId: modelId, modelDirectory: modelDirectory, toolCallFormat: toolCallFormat,
                runId: runId, preparedUserInput: preparedUserInput, rssLimitMB: rssLimitMB,
                generationStart: generationStart, parameters: parameters, eventBus: eventBus,
                cacheEntry: cacheEntry, inferenceConfiguration: inferenceConfiguration
            )

            generationCount += 1
            memoryMonitor.logSnapshot(generationCount: generationCount)
            persistPrefixCacheIfNeeded(
                prefixCache: prefixCache,
                modelDirectory: modelDirectory,
                toolCallFormat: toolCallFormat,
                inferenceConfiguration: inferenceConfiguration
            )
            if memoryMonitor.shouldUnloadAfterGeneration() {
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

    private func resolveCacheEntry(
        conversationId: String?,
        modelDirectory: URL,
        prefixCache: PrefixCacheContext? = nil,
        inferenceConfiguration: LocalModelInferenceConfiguration
    ) -> PromptCacheEntry? {
        guard let conversationId else { return nil }
        let cachePolicy = "ctx=\(inferenceConfiguration.contextLength):kv=\(inferenceConfiguration.maxKVSize):q4=\(inferenceConfiguration.kvCache4BitEnabled):prefix=\(prefixCache?.hash ?? "none")"
        let key = "\(promptCacheKey(conversationId: conversationId, modelDirectory: modelDirectory)):\(cachePolicy)"
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
        // Seed new conversations from the disk-persisted system-prefix cache.
        // The common-prefix machinery trims it to the system block, so only
        // the user message prefills.
        if let prefixCache, FileManager.default.fileExists(atPath: prefixCache.url.path) {
            if let loaded = Self.loadPrefixCache(prefixCache) {
                entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds)
                entry.systemHash = prefixCache.hash
            }
        }
        // A conversation-level cache (persisted before a critical eviction)
        // has more history than the system prefix — it wins.
        if let prefixCache,
           let loaded = Self.loadConversationCache(
               directory: prefixCache.url.deletingLastPathComponent(),
               conversationKey: key,
               expectedHash: prefixCache.hash
           ) {
            entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds)
            entry.systemHash = prefixCache.hash
        }
        return entry
    }

    /// Loads a conversation-level KV cache file, validating the system-hash
    /// metadata and token ids. Any mismatch falls back to the prefix/fresh
    /// prefill (safe).
    nonisolated private static func loadConversationCache(
        directory: URL,
        conversationKey: String,
        expectedHash: String
    ) -> (cache: [KVCache], tokenIds: [Int])? {
        let digest = String(SHA256.hash(data: Data(conversationKey.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        let url = directory.appendingPathComponent("kv-conv-\(digest).safetensors")
        guard FileManager.default.fileExists(atPath: url.path),
              let (caches, metadata) = try? loadPromptCache(url: url),
              metadata["systemHash"] == expectedHash,
              let tokenIdsRaw = metadata["tokenIds"] else {
            return nil
        }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else { return nil }
        return (caches, tokenIds)
    }

    /// Loads the disk prefix cache, validating the hash metadata. Returns nil
    /// (and deletes the stale file) on any mismatch — the caller falls back to
    /// a fresh prefill, which is always safe.
    nonisolated private static func loadPrefixCache(_ prefixCache: PrefixCacheContext) -> (cache: [KVCache], tokenIds: [Int])? {
        guard let (caches, metadata) = try? loadPromptCache(url: prefixCache.url),
              metadata["systemHash"] == prefixCache.hash,
              let tokenIdsRaw = metadata["tokenIds"] else {
            try? FileManager.default.removeItem(at: prefixCache.url)
            return nil
        }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else {
            try? FileManager.default.removeItem(at: prefixCache.url)
            return nil
        }
        return (caches, tokenIds)
    }

    /// Builds the system-only prefix cache (attention KV + linear-layer state
    /// over exactly the system block) and persists it, then evicts old files
    /// beyond the cap. Runs once per (project, settings) hash, in the
    /// background after the first generation.
    private func persistPrefixCacheIfNeeded(
        prefixCache: PrefixCacheContext?,
        modelDirectory: URL,
        toolCallFormat: ToolCallFormat?,
        inferenceConfiguration: LocalModelInferenceConfiguration
    ) {
        guard let prefixCache else { return }
        guard !savedPrefixCacheHashes.contains(prefixCache.hash) else { return }

        let capturedInput = UnsafeValue(value: prefixCache.systemUserInput)
        // Best-effort: the persist must NEVER delay a generation. It competes
        // via tryAcquire (skip instantly if the GPU is busy or a generation is
        // queued) — previously it took the full lock and blocked the next
        // tool-pass send for 20-30s while pre-computing the system KV.
        // savedPrefixCacheHashes is only marked on success, so a skipped
        // build is retried after a later (idle) generation.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                guard await MLXInferenceLock.shared.tryAcquire() else {
                    return // GPU busy or generation queued — skip, retried later
                }
                defer { Task { await MLXInferenceLock.shared.release() } }
do {
                    let container = try await self.loadContainerCached(
                        modelDirectory: modelDirectory, toolCallFormat: toolCallFormat
                    )
                    try await container.perform { context async throws in
                        let input = try await context.processor.prepare(input: capturedInput.value)
                        let tokenIds = input.text.tokens.asArray(Int.self)
                        let parameters = GenerateParameters(
                            maxTokens: 1,
                            maxKVSize: inferenceConfiguration.maxKVSize,
                            kvBits: inferenceConfiguration.kvCache4BitEnabled ? 4 : nil,
                            temperature: 0,
                            topP: 1,
                            prefillStepSize: inferenceConfiguration.prefillStepSize
                        )
                        var cache = context.model.newCache(parameters: parameters)
                        _ = try context.model.prepare(input, cache: cache, windowSize: parameters.prefillStepSize)
                        eval(cache)
                        try savePromptCache(
                            url: prefixCache.url,
                            cache: cache,
                            metadata: [
                                "systemHash": prefixCache.hash,
                                "tokenIds": tokenIds.map(String.init).joined(separator: ","),
                            ]
                        )
                    }
                    await self.markPrefixCacheSaved(prefixCache.hash)
                    Self.evictPrefixCacheFiles(directory: prefixCache.url.deletingLastPathComponent(), keep: Self.maxPrefixCacheFiles)
                } catch {
                // Cache building is best-effort; a failure just means the next
                // conversation pays a normal prefill.
                await AppLogger.shared.debug(
                    category: .localModel,
                    message: "prefix_cache_build_failed",
                    context: AppLogger.LogCallContext(metadata: [
                        "hash": prefixCache.hash,
                        "error": String(describing: error)
                    ])
                )
            }
        }
    }
}

private func markPrefixCacheSaved(_ hash: String) {
        savedPrefixCacheHashes.insert(hash)
    }

nonisolated private static let maxPrefixCacheFiles = 8

    nonisolated private static func evictPrefixCacheFiles(directory: URL, keep: Int) {
        guard let allFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let prefixFiles = allFiles.filter {
            $0.pathExtension == "safetensors" && $0.lastPathComponent.hasPrefix("kv-prefix-")
        }
        let sorted = prefixFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for file in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: file)
        }
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
        try memoryMonitor.throwIfExceeded(limitMB: rssLimitMB, phase: "before_container_load")
        let rssBeforeLoadMB = memoryMonitor.currentRSSMB()
        let loadStart = ContinuousClock.now
        let container = try await loadContainerCached(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
        let loadDuration = loadStart.duration(to: ContinuousClock.now)
        let rssAfterLoadMB = memoryMonitor.currentRSSMB()
        try memoryMonitor.throwIfExceeded(limitMB: rssLimitMB, phase: "after_container_load")
        await AIToolTraceLogger.shared.log(type: "mlx.model_loaded", data: [
            "runId": runId ?? "",
            "modelId": modelId,
            "loadMs": Self.milliseconds(loadDuration),
            "rssBeforeLoadMB": rssBeforeLoadMB,
            "rssAfterLoadMB": rssAfterLoadMB
        ])
        let capturedInput = UnsafeValue(value: preparedUserInput)
        let monitorForGen = memoryMonitor
        return try await container.perform { context in
            try monitorForGen.throwIfExceeded(limitMB: rssLimitMB, phase: "before_generation")

            let input = try await context.processor.prepare(input: capturedInput.value)
            let promptTokenCount = input.text.tokens.size
            let reservedOutputTokens = inferenceConfiguration.maxOutputTokens
            guard promptTokenCount + reservedOutputTokens <= inferenceConfiguration.contextLength else {
                throw AppError.aiServiceError(
                    "Local request exceeds the configured context window: \(promptTokenCount) prompt tokens + \(reservedOutputTokens) reserved output tokens exceed \(inferenceConfiguration.contextLength)."
                )
            }
            let promptTokenIds = input.text.tokens.asArray(Int.self)
            await AIToolTraceLogger.shared.log(type: "mlx.prompt_prepared", data: [
                "runId": runId ?? "",
                "modelId": modelId,
                "promptTokens": promptTokenCount,
                "contextLength": inferenceConfiguration.contextLength,
                "reservedOutputTokens": reservedOutputTokens,
                "contextHeadroomTokens": inferenceConfiguration.contextLength - promptTokenCount - reservedOutputTokens,
                "kvCache4Bit": inferenceConfiguration.kvCache4BitEnabled,
                "residentConversationCaches": promptCacheByConversation.count
            ])

            let (kvCache, effectiveInput) = try self.resolveKVCache(
                input: input,
                from: cacheEntry,
                promptTokenIds: promptTokenIds,
                parameters: parameters,
                context: context
            )

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
                // Exact token sequence written to the cache: prompt IDs plus the
                // IDs actually sampled (TokenIDRecorder). Deliberately not
                // re-encoded from `streamResult.output` — re-encoding can diverge
                // and desynchronize the next turn's common-prefix trim.
                cacheEntry.set(
                    cache: kvCache,
                    tokenIds: promptTokenIds + streamResult.generatedTokenIds
                )
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
                    // Suffix must be 1-D: the TokenIterator adds the batch
                    // axis itself (`step` applies [text: .newAxis]). A 2-D
                    // suffix produced a 4-D (B,1,S,H) model input, so the
                    // sequence length was read as 1 and the Qwen3.5 linear
                    // layers crashed their reshape on the second request.
                    let suffixTokens = Array(promptTokenIds[commonLen...])
                    effectiveInput = LMInput(
                        text: LMInput.Text(tokens: MLXArray(suffixTokens)),
                        image: nil, video: nil
                    )
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
        // Low-level iterator so we can wrap the sampling pipeline with a
        // token recorder — the generic generate() covers the docs but hides the
        // sampled IDs we need for robust KV-cache reuse bookkeeping.
        let recorder = TokenIDRecorder(upstream: parameters.processor())
        let iterator = try TokenIterator(
            input: input,
            model: context.model,
            cache: kvCache,
            processor: recorder,
            sampler: parameters.sampler(),
            prefillStepSize: parameters.prefillStepSize,
            maxTokens: parameters.maxTokens
        )
        let (stream, _) = MLXLMCommon.generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator,
            tools: nil
        )
        var result = StreamResult()

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
                await AIToolTraceLogger.shared.log(type: "mlx.first_token", data: [
                    "runId": runId ?? "",
                    "modelId": modelId,
                    "prefillMs": prefillMs,
                    "promptTokens": result.chunkCount,
                    "promptTokensPerSecond": result.chunkCount > 0 ? Double(result.chunkCount) / (Double(prefillMs) / 1000.0) : 0
                ])
            }

            switch generation {
            case .chunk(let text):
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
            }
        }

        result.generatedTokenIds = recorder.tokenIDs
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

    func hasActiveGeneration() -> Bool {
        activeGenerationCount > 0
    }

    /// Unloads every chat container + KV cache. When `persistKVTo` is set
    /// (critical memory pressure), each conversation's KV cache is written to
    /// disk first so the next turn restores it instead of re-prefilling the
    /// full history. Waits (bounded) for in-flight generations.
    ///
    /// The wait MUST be async: the in-flight generation's `activeGenerationCount`
    /// decrement runs on this actor, so a synchronous busy-wait here would block
    /// the very task that ends the generation (measured as a 30s stall).
    func unloadAllModels(reason: String = "unknown", persistKVTo: URL? = nil) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while activeGenerationCount > 0, ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        synchronizeMLXStream()
        if let persistKVTo {
            persistConversationCaches(to: persistKVTo)
        }
        // KV arrays are active MLX allocations, not allocator-cache entries.
        // Dropping only model containers left their conversation caches pinned
        // after a critical-pressure unload.
        promptCacheByConversation.removeAll()
        promptCacheAccessOrder.removeAll()
        containersByModelDirectory.removeAll()
        inFlightLoads.removeAll()
        accessOrder.removeAll()
        Memory.clearCache()
    }

    /// Best-effort disk persist of every in-memory conversation KV cache.
    /// Files: kv-conv-<sha256(conversationKey).prefix(16)>.safetensors with
    /// tokenIds + systemHash metadata; resolveCacheEntry restores them.
    private func persistConversationCaches(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (key, entry) in promptCacheByConversation {
            let (cache, tokenIds) = entry.get()
            guard let cache, !cache.isEmpty, !tokenIds.isEmpty else { continue }
            let digest = String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
            let url = dir.appendingPathComponent("kv-conv-\(digest).safetensors")
            try? savePromptCache(
                url: url,
                cache: cache,
                metadata: [
                    "tokenIds": tokenIds.map(String.init).joined(separator: ","),
                    "systemHash": entry.systemHash ?? "",
                ]
            )
        }
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
        let tokenizerLoader = LocalTokenizerLoader(directory: modelDirectory)
        // Fixed chat model (Qwen3.5-4B) is text-only — always the LLM factory.
        return try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory, using: tokenizerLoader)
    }
}

/// Bridges the huggingface swift-transformers AutoTokenizer into the
/// MLXLMCommon.Tokenizer protocol (model loading requires it).
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
