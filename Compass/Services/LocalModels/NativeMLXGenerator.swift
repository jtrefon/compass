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
    /// How many of `promptTokenIds` are the PROMPT part (the rest is the
    /// model's own generated output). The split makes the trim guard exact:
    /// removing generated tokens is always safe on non-trimmable SSM caches
    /// (the model's own output), regardless of size — only a trim that cuts
    /// into the prompt region is a genuine context rewrite.
    var promptTokenCount: Int = 0
    var systemHash: String?

    func set(cache: [KVCache]?, tokenIds: [Int], promptCount: Int) {
        self.cache = cache
        self.promptTokenIds = tokenIds
        self.promptTokenCount = promptCount
    }

    func get() -> (cache: [KVCache]?, tokenIds: [Int], promptCount: Int) {
        (cache, promptTokenIds, promptTokenCount)
    }

    func clear() {
        cache = nil
        promptTokenIds = []
        promptTokenCount = 0
        Memory.clearCache()
    }
}

protocol LocalModelGenerating: Sendable {
    func generate(modelId: String, modelDirectory: URL, userInput: sending UserInput, tools: [ToolSpec]?, toolCallFormat: ToolCallFormat?, runId: String?, inferenceConfiguration: LocalModelInferenceConfiguration, conversationId: String?, prefixCache: PrefixCacheContext?) async throws -> AIServiceResponse
    func preload(modelId: String, modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws
    func unloadAllModels(reason: String) async
    /// Release transient/scratch memory (MLX buffer cache) WITHOUT unloading
    /// weights or KV caches. Used by the pressure handler under the eviction
    /// policy — chat inference state must survive memory pressure.
    func releaseTransientMemory() async
    /// LAST-RESORT pressure eviction: drops the resident conversation KV cache
    /// (not the model weights). The next turn pays a full prefill, but the
    /// system stops compressor-thrashing. Only called when memory pressure is
    /// critical AND the compressor is saturated.
    func releaseConversationKV() async
    /// Current OS compressor pages (for the pressure policy decision).
    func currentCompressorPages() async -> Int?
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
    private let modelRepository: MLXModelRepository
    private var generationCount: Int = 0
    /// Generations currently executing; the unload path waits for these
    /// (defense in depth — the pressure handler already holds
    /// MLXInferenceLock, this guards the non-locked unload callers).
    private var activeGenerationCount = 0
    private static let mlxCacheLimitBytes = 1024 * 1024 * 1024
    /// Trims below this bound are the model's own previous generation —
    /// safe to reuse on non-trimmable SSM caches (the state's stale content
    /// is gated/decayed and empirically benign). Above it the trim is a
    /// genuine context rewrite → fresh prefill.
    private static let maxStaleTrimTokens = 4_096
    private let conversationCache: ConversationKVCache
    private let memoryMonitor: any EngineMemoryMonitoring

    nonisolated static let sharedTestGenerator: LocalModelGenerating = {
        NativeMLXGenerator(eventBus: NoOpEventBus())
    }()

    init(
        eventBus: EventBusProtocol,
        memoryMonitor: any EngineMemoryMonitoring = ProcessMemoryMonitor(),
        modelRepository: MLXModelRepository = MLXModelRepository(),
        conversationCache: ConversationKVCache = ConversationKVCache()
    ) {
        self.eventBus = eventBus
        self.memoryMonitor = memoryMonitor
        self.modelRepository = modelRepository
        self.conversationCache = conversationCache
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
        // Lock the process's memory so the OS cannot swap/compress our pages
        // mid-inference (measured: 7GB in swap + 200-400k compressed pages
        // while decode ran at 12 tps vs a 35+ tps clean benchmark). MCL_FUTURE
        // keeps KV growth and generation buffers resident too. Opt out via
        // COMPASS_DISABLE_MEMORY_LOCK=1 (allocation failures instead of swap
        // under genuine RAM exhaustion).
        ProcessMemoryLock.engageIfEnabled()
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
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let ncpu = ProcessInfo.processInfo.processorCount
        let activeCPU = ProcessInfo.processInfo.activeProcessorCount
        let availableMemMB: Int = {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let r = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rp in task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rp, &count) } }
            guard r == KERN_SUCCESS else { return 0 }
            return Int(info.resident_size / 1024 / 1024)
        }()
        await AIToolTraceLogger.shared.log(type: "mlx.device_info", data: [
            "defaultDeviceType": deviceType,
            "deviceDescription": deviceDesc,
            "gpuArchitecture": gpuArch,
            "maxRecommendedWorkingSetMB": maxWorkingSetMB,
            "systemMemoryMB": systemMemMB,
            "mlxCacheLimitMB": cacheLimitMB,
            "mlxMemoryLimitMB": memoryLimitMB,
            "thermalState": thermal,
            "processorCount": ncpu,
            "activeProcessorCount": activeCPU,
            "residentMBAtBoot": availableMemMB
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
        let lockWaitStart = ContinuousClock.now
        try await MLXInferenceLock.shared.acquire()
        let lockWaitMs = Self.milliseconds(lockWaitStart.duration(to: ContinuousClock.now))
        if lockWaitMs > 5 {
            AIToolTraceLogger.shared.logIfEnabled(type: "mlx.lock_wait", data: ["runId": runId ?? "", "waitMs": lockWaitMs])
        }
        try Task.checkCancellation()
        // Pre-generation memory gate: evict FIM only when free memory is low.
        // The unconditional eviction that was here caused 99 pre_evict_fim
        // events per session and 15 × 30s lock timeouts — FIM was reloaded
        // after every chat generation. With FP16 KV (lower transient peak),
        // the conditional guard should rarely fire.
        if let vm = memoryMonitor.currentVMStat(), vm.freePages < Self.fimEvictionFreePageThreshold {
            AIToolTraceLogger.shared.logIfEnabled(type: "mlx.memory_gate", data: ["runId": runId ?? "", "freePages": vm.freePages, "compressorPages": vm.compressorPages, "action": "pre_evict_fim"])
            await InferenceUnloadRegistry.shared.unloadAll(labels: [InferenceUnloadRegistry.fimLabel])
            // Brief throttle to let compressor drain (live trace shows 22173→95614 after 2.5s)
            try? await Task.sleep(for: .milliseconds(Self.fimEvictionDrainMs))
        }
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
            maxKVSize: inferenceConfiguration.mlxMaxKVSize,
            kvBits: inferenceConfiguration.kvCache4BitEnabled ? 4 : nil,
            temperature: inferenceConfiguration.temperature,
            topP: inferenceConfiguration.topP,
            repetitionPenalty: inferenceConfiguration.repetitionPenalty,
            repetitionContextSize: inferenceConfiguration.repetitionContextSize,
            prefillStepSize: inferenceConfiguration.prefillStepSize
        )
        let eventBus = self.eventBus
        let cacheEntry = await resolveCacheEntry(
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
                cacheEntry: cacheEntry, prefixCache: prefixCache,
                inferenceConfiguration: inferenceConfiguration
            )

            generationCount += 1
            memoryMonitor.logSnapshot(generationCount: generationCount)
            await persistPrefixCacheIfNeeded(
                prefixCache: prefixCache,
                modelDirectory: modelDirectory,
                toolCallFormat: toolCallFormat,
                inferenceConfiguration: inferenceConfiguration
            )
            if memoryMonitor.shouldUnloadAfterGeneration() {
                await unloadModel(modelDirectory: modelDirectory, reason: "post_generation_env_flag")
            }

            return response
        } catch {
            // Keep the container on cancellation and transient stream errors —
            // unloading here meant pressing Stop cost a full ~2.5GB reload and
            // dropped every conversation's KV cache. Only load-time/RSS
            // failures and explicit unload requests should tear it down.
            if !(error is CancellationError) && !Task.isCancelled {
                await unloadModel(modelDirectory: modelDirectory, reason: "generation_error")
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
    ) async -> PromptCacheEntry? {
        await conversationCache.resolveEntry(
            conversationId: conversationId,
            modelDirectory: modelDirectory,
            prefixCache: prefixCache,
            kvCache4Bit: inferenceConfiguration.kvCache4BitEnabled
        )
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
    ) async {
        guard let prefixCache else { return }
        guard await !conversationCache.hasPrefixCache(prefixCache.hash) else { return }

        let capturedInput = UnsafeValue(value: prefixCache.systemUserInput)
        // Best-effort: the persist must NEVER delay a generation. It competes
        // via tryAcquire (skip instantly if the GPU is busy or a generation is
        // queued) — previously it took the full lock and blocked the next
        // tool-pass send for 20-30s while pre-computing the system KV.
        // savedPrefixCacheHashes is only marked on success, so a skipped
        // build is retried after a later (idle) generation.
        let conversationCache = self.conversationCache
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
                            maxKVSize: inferenceConfiguration.mlxMaxKVSize,
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
                    await conversationCache.markPrefixCacheSaved(prefixCache.hash)
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
        prefixCache: PrefixCacheContext?,
        inferenceConfiguration: LocalModelInferenceConfiguration
    ) async throws -> AIServiceResponse {
        let defaultDevice = Device.defaultDevice()
        let deviceType = defaultDevice.deviceType?.rawValue ?? "unknown"
        try memoryMonitor.throwIfExceeded(limitMB: rssLimitMB, phase: "before_container_load")
        await logMemorySnapshot(phase: "before_container_load", runId: runId)
        let rssBeforeLoadMB = memoryMonitor.currentRSSMB()
        let loadStart = ContinuousClock.now
        let container = try await loadContainerCached(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
        let loadDuration = loadStart.duration(to: ContinuousClock.now)
        let rssAfterLoadMB = memoryMonitor.currentRSSMB()
        try memoryMonitor.throwIfExceeded(limitMB: rssLimitMB, phase: "after_container_load")
        await logMemorySnapshot(phase: "after_container_load", runId: runId)
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
            // Detailed pre-generation snapshot for hour-long runs (includes vm_stat)
            let snapBefore = Memory.snapshot()
            let vmBefore = monitorForGen.currentVMStat()
            await AIToolTraceLogger.shared.log(type: "mlx.memory_snapshot", data: [
                "runId": runId ?? "unknown",
                "phase": "before_generation",
                "activeMB": snapBefore.activeMemory / (1024 * 1024),
                "cacheMB": snapBefore.cacheMemory / (1024 * 1024),
                "peakMB": snapBefore.peakMemory / (1024 * 1024),
                "rssMB": monitorForGen.currentRSSMB(),
                "thermalState": monitorForGen.currentThermalState(),
                "vmFreePages": vmBefore?.freePages ?? 0,
                "vmCompressorPages": vmBefore?.compressorPages ?? 0,
                "generationCount": generationCount
            ])

            let input = try await context.processor.prepare(input: capturedInput.value)
            let promptTokenCount = input.text.tokens.size
            let remainingOutputTokens = inferenceConfiguration.contextLength - promptTokenCount
            guard remainingOutputTokens > 0 else {
                throw AppError.aiServiceError(
                    "Local request exceeds the configured context window: \(promptTokenCount) prompt tokens leave no room for output in \(inferenceConfiguration.contextLength)."
                )
            }
            // "Let the model generate what it needs" bounded by the context
            // that actually remains — a fixed 32k reserve starved small
            // windows (64k ctx → 27k history → premature drops → collapses).
            let effectiveMaxTokens = min(inferenceConfiguration.maxOutputTokens, remainingOutputTokens)
            let clampedParameters = GenerateParameters(
                maxTokens: effectiveMaxTokens,
                maxKVSize: parameters.maxKVSize,
                kvBits: parameters.kvBits,
                temperature: parameters.temperature,
                topP: parameters.topP,
                repetitionPenalty: parameters.repetitionPenalty,
                repetitionContextSize: parameters.repetitionContextSize,
                prefillStepSize: parameters.prefillStepSize
            )
            let promptTokenIds = input.text.tokens.asArray(Int.self)
            // Publish initial context estimate for live status bar (mirrors cloud path)
            if let runId {
                let initialEstimate = promptTokenCount
                Task { @MainActor in
                    eventBus.publish(StreamingContextUsageEvent(runId: runId, estimatedPromptTokens: initialEstimate))
                }
            }
            await AIToolTraceLogger.shared.log(type: "mlx.prompt_prepared", data: [
                "runId": runId ?? "",
                "modelId": modelId,
                "promptTokens": promptTokenCount,
                "contextLength": inferenceConfiguration.contextLength,
                "reservedOutputTokens": effectiveMaxTokens,
                "contextHeadroomTokens": remainingOutputTokens - effectiveMaxTokens,
                "kvCache4Bit": inferenceConfiguration.kvCache4BitEnabled,
                "residentConversationCaches": cacheEntry != nil ? 1 : 0
            ])

            var (kvCache, effectiveInput) = try self.resolveKVCache(
                input: input,
                from: cacheEntry,
                promptTokenIds: promptTokenIds,
                parameters: clampedParameters,
                context: context,
                prefixCache: prefixCache,
                runId: runId
            )

            MLX.Memory.peakMemory = 0
            let genStart = ContinuousClock.now
            // Fresh-prefill path: allocate the cache HERE so it is ours to
            // repopulate afterwards. resolveKVCache returns nil on miss, and
            // without this the entry was never refilled after a fresh
            // prefill (cached=0 on EVERY subsequent turn → full re-prefill
            // each turn — the "minutes between turns" regression).
            if kvCache == nil {
                kvCache = context.model.newCache(parameters: clampedParameters)
            }

            let streamResult = try await self.processGeneration(
                input: effectiveInput,
                kvCache: kvCache,
                parameters: clampedParameters,
                context: context,
                runId: runId,
                eventBus: eventBus,
                rssLimitMB: rssLimitMB,
                genStart: genStart,
                modelId: modelId,
                fullPromptTokenCount: promptTokenCount
            )

            if let cacheEntry, let kvCache, !kvCache.isEmpty {
                // Exact token sequence written to the cache: prompt IDs plus the
                // IDs actually sampled (TokenIDRecorder). Deliberately not
                // re-encoded from `streamResult.output` — re-encoding can diverge
                // and desynchronize the next turn's common-prefix trim.
                cacheEntry.set(
                    cache: kvCache,
                    tokenIds: promptTokenIds + streamResult.generatedTokenIds,
                    promptCount: promptTokenIds.count
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
        context: ModelContext,
        prefixCache: PrefixCacheContext? = nil,
        runId: String? = nil
    ) throws -> (kvCache: [KVCache]?, effectiveInput: LMInput) {
        var effectiveInput = input
        var kvCache: [KVCache]? = nil
        var reuseSkippedReason = ""
        var skippedCommonLen = 0
        var skippedTrimCount = 0

        let (cachedCache, cachedTokenIds, cachedPromptCount) = cacheEntry?.get() ?? (nil, [], 0)
        if let cachedCache, !cachedCache.isEmpty, !cachedTokenIds.isEmpty, !promptTokenIds.isEmpty {
            let commonLen = Self.commonPrefixLength(cachedTokenIds, promptTokenIds)
            let trimCount = cachedTokenIds.count - commonLen

            if commonLen > 0 {
                var reuseCache: [KVCache] = []
                var skipReuse = false

                // Non-trimmable caches (MambaCache in Qwen 3.5) cannot be
                // rewound, but a SMALL trim only removes the model's own
                // previous generation (50-4000 tokens, heavily decayed by the
                // SSM gating) — empirically safe (hours of 46-56k reuse).
                // A trim that stays inside the GENERATED region is safe at ANY
                // size by that same rationale (the entry's prompt/generated
                // split makes this exact — long 8K generations no longer break
                // the chain). A trim cutting into the PROMPT region is a
                // genuine context rewrite and must not run on top of stale
                // recurrent state — bounded by maxStaleTrimTokens. The
                // original guard skipped reuse on ANY trim, which killed the
                // chain on turn 1 (system-prefix seed has a ~4-token drift)
                // and re-prefilled the full 13k prompt on EVERY turn.
                let trimIsGeneratedOnly = commonLen >= cachedPromptCount
                if !trimIsGeneratedOnly, trimCount > Self.maxStaleTrimTokens,
                   cachedCache.contains(where: { !$0.isTrimmable }) {
                    skipReuse = true
                    reuseSkippedReason = "non_trimmable_large_trim"
                    skippedCommonLen = commonLen
                    skippedTrimCount = trimCount
                }

                if !skipReuse {
                    for cache in cachedCache {
                        if let maxSize = cache.maxSize, cache.offset > maxSize {
                            skipReuse = true
                            reuseSkippedReason = "offset_exceeds_max_size"
                            break
                        }
                        if trimCount > 0 {
                            _ = cache.trim(trimCount)
                        }
                        reuseCache.append(cache)
                    }
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
            // STAGED FALLBACK: exact-prefix reuse was rejected (history
            // divergence), but the system block is stable — restore its KV
            // (full SSM state) from the disk prefix cache and prefill only
            // the remainder. This bounds every divergence recovery to
            // prompt - systemPrefix instead of a full re-prefill, and keeps
            // the reuse chain alive (entry is repopulated post-generation).
            if let cacheEntry, let prefixCache,
               FileManager.default.fileExists(atPath: prefixCache.url.path),
               let loaded = ConversationKVCache.loadPrefixCache(prefixCache) {
                cacheEntry.set(cache: loaded.cache, tokenIds: loaded.tokenIds, promptCount: loaded.tokenIds.count)
                cacheEntry.systemHash = prefixCache.hash
                let systemCommonLen = Self.commonPrefixLength(loaded.tokenIds, promptTokenIds)
                let systemTrim = loaded.tokenIds.count - systemCommonLen
                if systemCommonLen > 0, systemTrim <= Self.maxStaleTrimTokens {
                    var recovered: [KVCache] = []
                    var recoveredOK = true
                    for c in loaded.cache {
                        if let maxSize = c.maxSize, c.offset > maxSize {
                            recoveredOK = false
                            break
                        }
                        if systemTrim > 0 {
                            _ = c.trim(systemTrim)
                        }
                        recovered.append(c)
                    }
                    if recoveredOK {
                        let suffixTokens = Array(promptTokenIds[systemCommonLen...])
                        effectiveInput = LMInput(
                            text: LMInput.Text(tokens: MLXArray(suffixTokens)),
                            image: nil, video: nil
                        )
                        kvCache = recovered
                        reuseSkippedReason = "recovered_via_system_prefix"
                    }
                }
            }
        }

        if kvCache == nil {
            if let cacheEntry {
                cacheEntry.clear()
            }
            kvCache = context.model.newCache(parameters: parameters)
        }

        Self.logKVTelemetry(cacheEntry: cacheEntry, kvCache: kvCache, effectiveInput: effectiveInput, promptTokenIds: promptTokenIds, runId: runId, parameters: parameters, reuseSkippedReason: reuseSkippedReason, skippedCommonLen: skippedCommonLen, skippedTrimCount: skippedTrimCount)

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
        modelId: String,
        fullPromptTokenCount: Int
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
            maxTokens: parameters.maxTokens,
            kvBits: parameters.kvBits,
            kvGroupSize: parameters.kvGroupSize,
            quantizedKVStart: parameters.quantizedKVStart,
            kvScheme: parameters.kvScheme
        )
        let (stream, _) = MLXLMCommon.generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator,
            tools: nil
        )
        var result = StreamResult()
        // Chunk-level timing: average tps (mlx.generate_complete) cannot
        // distinguish steady-slow decode from stall bursts. Sample the first
        // ~16 chunks + a 1/50 cadence afterwards to expose intra-generation
        // stalls (memory allocation waits, compressor hits).
        let chunkTimingStart = ContinuousClock.now
        var lastChunkTiming = chunkTimingStart
        var chunkTimingLogCount = 0
        // Streaming chunk batching: accumulate text and flush on a time
        // throttle to reduce per-token main-thread dispatches.
        var streamingChunkBuffer = ""
        var lastChunkFlush = chunkTimingStart

        for await generation in stream {
            if Task.isCancelled {
                throw CancellationError()
            }
            if result.chunkCount % 50 == 0 {
                try Self.throwIfProcessRSSExceeded(limitMB: rssLimitMB, phase: "streaming")
            }
            result.chunkCount += 1
            // Every chunk in the first 16, then every 50th — bounded log volume.
            // Gated by TelemetryGate: the entire timing block is compiled out
            // in Release (zero overhead — no ContinuousClock calls, no math).
            if TelemetryGate.isEnabled, chunkTimingLogCount < 16 || result.chunkCount % 50 == 0 {
                let now = ContinuousClock.now
                let sinceLastMs = Self.milliseconds(lastChunkTiming.duration(to: now))
                let sinceStartMs = Self.milliseconds(chunkTimingStart.duration(to: now))
                if sinceLastMs >= 10 {
                    let logRunId = runId ?? "unknown"
                    let logChunk = result.chunkCount
                    let logTokens = recorder.tokenCount
                    let logSinceLastMs = sinceLastMs
                    let logSinceStartMs = sinceStartMs
                    let logInstantTps = sinceLastMs > 0 ? round(1000.0 / Double(sinceLastMs)) : 0
                    let logStallMs = sinceLastMs > 500 ? sinceLastMs : 0
                    AIToolTraceLogger.shared.logIfEnabled(type: "mlx.chunk_timing", data: [
                        "runId": logRunId,
                        "chunk": logChunk,
                        "tokens": logTokens,
                        "sinceLastMs": logSinceLastMs,
                        "sinceStartMs": logSinceStartMs,
                        "instantTps": logInstantTps,
                        "stallMs": logStallMs
                    ])
                }
                lastChunkTiming = now
                chunkTimingLogCount += 1
            }
            if TelemetryGate.isEnabled, result.chunkCount == 1 {
                let prefillMs = Self.milliseconds(genStart.duration(to: ContinuousClock.now))
                let effectivePromptTokens = input.text.tokens.size
                AIToolTraceLogger.shared.logIfEnabled(type: "mlx.first_token", data: [
                    "runId": runId ?? "",
                    "modelId": modelId,
                    "prefillMs": prefillMs,
                    "promptTokens": effectivePromptTokens,
                    "promptTokensPerSecond": effectivePromptTokens > 0 && prefillMs > 0 ? Double(effectivePromptTokens) / (Double(prefillMs) / 1000.0) : 0,
                    "chunkCount": result.chunkCount
                ])
                AIToolTraceLogger.shared.logIfEnabled(type: "mlx.inference_timeline", data: [
                    "runId": runId ?? "",
                    "modelId": modelId,
                    "phase": "ttft",
                    "prefillMs": prefillMs,
                    "promptTokens": effectivePromptTokens,
                    "prefillTokensPerSecond": effectivePromptTokens > 0 && prefillMs > 0 ? Double(effectivePromptTokens) / (Double(prefillMs) / 1000.0) : 0
                ])
            }

            switch generation {
            case .chunk(let text):
                result.output.append(text)
                if let runId, !text.isEmpty {
                    // Batch streaming chunks: accumulate text and publish on a
                    // time throttle (~33ms = 30fps) to avoid per-token
                    // main-thread dispatches. At 30 t/s this cuts event bus
                    // traffic from 30 events/sec to ~1 event/sec (the UI
                    // renders at 60fps but text updates at 30fps are smooth).
                    streamingChunkBuffer.append(text)
                    let now = ContinuousClock.now
                    let sinceLastFlushMs = Self.milliseconds(lastChunkFlush.duration(to: now))
                    if sinceLastFlushMs >= Self.streamingFlushIntervalMs {
                        let batch = streamingChunkBuffer
                        streamingChunkBuffer = ""
                        lastChunkFlush = now
                        eventBus.publish(LocalModelStreamingChunkEvent(runId: runId, chunk: batch))
                        // Live context: update estimate with each flush —
                        // one main-actor hop per ~33ms instead of per token.
                        // Use the FULL prompt length (not the trimmed suffix
                        // input): suffix-only made the gauge oscillate ~1-2k
                        // per turn while the model actually ran at 18-24k.
                        let estimate = fullPromptTokenCount + recorder.tokenCount
                        Task { @MainActor in
                            eventBus.publish(StreamingContextUsageEvent(runId: runId, estimatedPromptTokens: estimate))
                        }
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

        // Flush any remaining buffered streaming text after the loop ends.
        if let runId, !streamingChunkBuffer.isEmpty {
            eventBus.publish(LocalModelStreamingChunkEvent(runId: runId, chunk: streamingChunkBuffer))
            streamingChunkBuffer = ""
        }

        let generatedTokenIds = recorder.tokenIDs
        result.generatedTokenIds = generatedTokenIds
        if let runId {
            let finalEstimate = fullPromptTokenCount + generatedTokenIds.count
            Task { @MainActor in
                eventBus.publish(StreamingContextUsageEvent(runId: runId, estimatedPromptTokens: finalEstimate, isFinal: true))
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
        let vm = self.memoryMonitor.currentVMStat()
        let thermal = self.memoryMonitor.currentThermalState()
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
            "thermalState": thermal,
            "vmFreePages": vm?.freePages ?? 0,
            "vmCompressorPages": vm?.compressorPages ?? 0,
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

    private func logMemorySnapshot(phase: String, runId: String?) async {
        guard TelemetryGate.isEnabled else { return }
        let snapshot = Memory.snapshot()
        let rssMB = memoryMonitor.currentRSSMB()
        // genPeakMB is the allocator HIGH-WATER mark since the last generation
        // reset (transient prefill activations spike it, then free) — it is
        // NOT resident memory. activeMB (weights + live KV) and cacheMB
        // (bounded 1GB buffer pool) are the "how much is held" metrics.
        await AIToolTraceLogger.shared.log(type: "mlx.memory_snapshot", data: [
            "runId": runId ?? "unknown",
            "phase": phase,
            "activeMB": snapshot.activeMemory / (1024 * 1024),
            "cacheMB": snapshot.cacheMemory / (1024 * 1024),
            "genPeakMB": snapshot.peakMemory / (1024 * 1024),
            "rssMB": rssMB,
            "generationCount": generationCount
        ])
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000) + (Double(duration.components.attoseconds) / 1_000_000_000_000_000))
    }

    // MARK: - Memory gate constants

    /// Free page count below which FIM is evicted before chat generation.
    /// 20k pages ≈ 78 MB free — below this, the compressor thrashes and
    /// decode stalls reach 30+ seconds. Evicting FIM frees ~1.5 GB.
    nonisolated private static let fimEvictionFreePageThreshold = 20_000

    /// Pause after FIM eviction to let the compressor drain before starting
    /// generation. Live trace shows compressor pages dropping from 327k to
    /// 95k within ~2.5s of eviction; 200ms is the minimum useful pause.
    nonisolated private static let fimEvictionDrainMs = 200

    /// Streaming chunk flush interval: accumulate text and publish to the
    /// event bus at most every ~33ms (30fps). Reduces per-token main-thread
    /// dispatches from N/sec to ~30/sec while keeping the UI smooth.
    nonisolated private static let streamingFlushIntervalMs = 33

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

    func currentCompressorPages() async -> Int? {
        memoryMonitor.currentVMStat()?.compressorPages
    }

    /// Unloads every chat container + KV cache. Waits (bounded) for in-flight
    /// generations.
    ///
    /// The wait MUST be async: the in-flight generation's `activeGenerationCount`
    /// decrement runs on this actor, so a synchronous busy-wait here would block
    /// the very task that ends the generation (measured as a 30s stall).
    ///
    /// Callers are policy-gated — chat inference state is only unloaded on
    /// provider changes (offline toggle, model switch) or errors, never on
    /// memory pressure.
    func unloadAllModels(reason: String = "unknown") async {
        let deadline = ContinuousClock.now + .seconds(30)
        while activeGenerationCount > 0, ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Stream().synchronize()
        // Persist the resident conversation KV to disk so a session break
        // resumes with a disk-load + delta instead of a full re-prefill.
        // Best-effort; bounded disk usage.
        await persistActiveConversation()
        // KV arrays are active MLX allocations, not allocator-cache entries.
        // Dropping only model containers left their conversation caches pinned
        // after a critical-pressure unload.
        await conversationCache.clearAll()
        await modelRepository.unloadAll()
        Memory.clearCache()
    }

    /// Persists the single resident conversation's KV to disk (Fix 3). Called
    /// on unload/session end so the next run of the same conversation resumes
    /// fast. Best-effort, bounded by `maxConversationCacheFiles`.
    private func persistActiveConversation() async {
        // The generator knows the active conversation from the last resolve;
        // re-resolve it from the cache's single resident entry.
        await conversationCache.persistActiveConversationIfPossible()
    }

    /// Releases transient/scratch memory WITHOUT unloading weights or KV
    /// caches — chat inference state must survive memory pressure (eviction
    /// policy: provider changes only). The MLX buffer cache is GPU scratch
    /// (not weights/KV); dropping it is safe and frees allocator headroom.
    func releaseTransientMemory() async {
        Stream().synchronize()
        Memory.clearCache()
        await AIToolTraceLogger.shared.log(type: "mlx.transient_release", data: [
            "reason": "memory_pressure_critical",
            "residentMB": memoryMonitor.currentRSSMB()
        ])
    }

    /// LAST-RESORT pressure eviction: drops the resident conversation KV cache
    /// (not the model weights). The next turn pays a full prefill, but the
    /// system stops compressor-thrashing. Only called when memory pressure is
    /// critical AND the compressor is saturated.
    func releaseConversationKV() async {
        Stream().synchronize()
        await conversationCache.clearAll()
        Memory.clearCache()
        await AIToolTraceLogger.shared.log(type: "mlx.transient_release", data: [
            "reason": "pressure_critical_conversation_kv",
            "residentMB": memoryMonitor.currentRSSMB()
        ])
    }

    private func loadContainerCached(modelDirectory: URL, toolCallFormat: ToolCallFormat? = nil) async throws -> ModelContainer {
        try await modelRepository.load(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
    }

    func unloadModel(modelDirectory: URL, reason: String = "unknown") async {
        Stream().synchronize()
        await persistActiveConversation()
        await conversationCache.clearAll()
        await modelRepository.unload(modelDirectory: modelDirectory)
        Memory.clearCache()
    }

    private static func logKVTelemetry(
        cacheEntry: PromptCacheEntry?,
        kvCache: [KVCache]?,
        effectiveInput: LMInput,
        promptTokenIds: [Int],
        runId: String?,
        parameters: GenerateParameters,
        reuseSkippedReason: String?,
        skippedCommonLen: Int?,
        skippedTrimCount: Int?
    ) {
        let (cachedCount, cachedOffset, cachedMaxSize) = {
            if let c = cacheEntry?.get().cache?.first {
                return (cacheEntry?.get().cache?.count ?? 0, c.offset, c.maxSize ?? 0)
            }
            return (0, 0, 0)
        }()
        let hit = kvCache != nil && !(cacheEntry?.get().cache?.isEmpty ?? true) && effectiveInput.text.tokens.size < promptTokenIds.count
        let logCommonLen: Int
        if let tokenIds = cacheEntry?.get().tokenIds, tokenIds.count > 0 {
            logCommonLen = commonPrefixLength(tokenIds, promptTokenIds)
        } else {
            logCommonLen = 0
        }
        let logTrimCount = (cacheEntry?.get().tokenIds.count ?? 0) - logCommonLen
        AIToolTraceLogger.shared.logIfEnabled(type: "mlx.kv_cache", data: [
            "runId": runId ?? "unknown",
            "hit": hit,
            "commonLen": logCommonLen,
            "suffixLen": effectiveInput.text.tokens.size,
            "promptLen": promptTokenIds.count,
            "trimCount": logTrimCount,
            "cachedCount": cachedCount,
            "cachedOffset": cachedOffset,
            "cachedMaxSize": cachedMaxSize,
            "reuseSkippedReason": reuseSkippedReason as Any,
            "skippedCommonLen": skippedCommonLen as Any,
            "skippedTrimCount": skippedTrimCount as Any,
            "kvCache4Bit": parameters.kvBits == 4,
            "cacheKind": "rotating-full",
            "maxKVSize": parameters.maxKVSize,
            "prefillStepSize": parameters.prefillStepSize
        ])
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
