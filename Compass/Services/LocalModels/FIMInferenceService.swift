import Foundation
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

actor FIMInferenceService {
    private var modelContainer: ModelContainer?
    nonisolated let modelId: String
    private let modelDirectory: URL
    private var generationTask: Task<Void, Never>?

    /// Re-prefill length for the variant-decode trick (see §4 of
    /// FIM_VariantPools_Arch.md): the cache is trimmed to promptLen - K and
    /// the last K prompt tokens re-prefilled — identical K/V, ~5ms.
    private static let variantTrimBackTokens = 8

    /// First token ID of the most recent generation (for building the ban set
    /// of the next variant).
    private(set) var lastGeneratedFirstTokenID: Int?

    /// Reference box so a @Sendable perform closure can hand the warm cache
    /// and processor capture back to the actor.
    private final class GenerationStateBox: @unchecked Sendable {
        var cache: [KVCache]?
        var processor: FIMBannedTokenProcessor?
    }

    // Warm KV cache + prompt tokens from the previous request (FIM_Spec.md §5).
    // Only one cursor position exists at a time: the previous request's cache
    // is trimmed to the common prefix and the delta is re-encoded per call.
    private var kvCache: [KVCache]?
    private var cachedPromptTokens: [Int] = []
    /// Cache array capacity (offset after the previous generation = prompt +
    /// generated tokens). The RotatingKVCache array does not shrink on trim;
    /// a multi-token prefill write beyond it is clamped and silently drops
    /// tokens — so reuse is only safe while the new prompt fits the capacity.
    private var cachedOffset: Int = 0

    init(modelId: String) async throws {
        self.modelId = modelId
        guard !modelId.isEmpty else {
            throw AppError.aiServiceError("No local model selected for completions.")
        }
        guard let model = LocalModelCatalog.model(id: modelId) else {
            throw AppError.aiServiceError("Selected completion model is not recognized: \(modelId)")
        }
        guard LocalModelFileStore.isModelInstalled(model) else {
            throw AppError.aiServiceError("Completion model is not downloaded: \(model.displayName)")
        }
        self.modelDirectory = try LocalModelFileStore.fimModelDirectory()
    }

    private struct FIMTokenizerLoader: TokenizerLoader {
        let modelDirectory: URL
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            let upstream = try await AutoTokenizer.from(modelFolder: modelDirectory)
            return FIMTokenBridge(upstream: upstream)
        }
    }

    private final class FIMTokenBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
        let upstream: any Tokenizers.Tokenizer
        init(upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
            throw AppError.aiServiceError("Chat templates are not supported for FIM models. Use direct encoding.")
        }
    }

    private func ensureLoaded() async throws -> ModelContainer {
        if let container = modelContainer { return container }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: FIMTokenizerLoader(modelDirectory: modelDirectory)
        )
        modelContainer = container
        return container
    }

    func unload() {
        generationTask?.cancel()
        generationTask = nil
        kvCache = nil
        cachedPromptTokens = []
        cachedOffset = 0
        modelContainer = nil
    }

    private func truncateInput(prefix: inout String, suffix: inout String, contextLength: Int, maxTokens: Int) {
        let reservedTokens = 20
        let maxInputTokens = contextLength - maxTokens - reservedTokens
        guard maxInputTokens > 0 else { return }

        let safeCharsPerToken = 2
        let maxChars = maxInputTokens * safeCharsPerToken

        let totalChars = prefix.count + suffix.count
        guard totalChars > maxChars else { return }

        let maxSuffixChars = maxChars / 3

        if suffix.count > maxSuffixChars {
            suffix = String(suffix.prefix(maxSuffixChars))
        }
        if prefix.count > maxChars - suffix.count {
            prefix = String(prefix.suffix(maxChars - suffix.count))
        }
    }

    /// Reuse the previous request's warm KV cache when the new prompt shares a
    /// token prefix with it (the common case while typing: the file content
    /// before the cursor is unchanged). Mirrors `NativeMLXGenerator.resolveKVCache`.
    /// `cachedOffset` guards the rotating-cache array capacity: the array does
    /// not shrink on trim, so a longer prompt would clamp its prefill write
    /// and silently lose tokens (measured as rambling + quality drop).
    private nonisolated static func resolveKVCache(
        input: LMInput,
        cachedTokens: [Int],
        cachedCache: [KVCache]?,
        cachedOffset: Int,
        promptTokenIds: [Int],
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> (kvCache: [KVCache]?, effectiveInput: LMInput) {
        var effectiveInput = input
        var kvCache: [KVCache]? = nil

        if let cachedCache, !cachedCache.isEmpty, !cachedTokens.isEmpty, !promptTokenIds.isEmpty,
           promptTokenIds.count <= cachedOffset {
            let commonLen = Self.commonPrefixLength(cachedTokens, promptTokenIds)

            if commonLen > 0 {
                var reuseCache: [KVCache] = []
                var skipReuse = false
                for cache in cachedCache {
                    if let maxSize = cache.maxSize, cache.offset > maxSize {
                        skipReuse = true
                        break
                    }
                    // Trim to the shared prefix. The cache offset includes the
                    // previous generation's tokens (prompt + generated), so
                    // the trim must be offset-based, not prompt-token-based —
                    // otherwise stale generated tokens stay cached and offsets
                    // desynchronize (measured as rambling + quality drop).
                    let trimCount = cache.offset - commonLen
                    if trimCount > 0 {
                        _ = cache.trim(trimCount)
                    }
                    reuseCache.append(cache)
                }

                if !skipReuse, commonLen < promptTokenIds.count {
                    // Only the delta after the common prefix is re-encoded.
                    let suffixTokens = Array(promptTokenIds[commonLen...])
                    effectiveInput = LMInput(text: LMInput.Text(tokens: MLXArray(suffixTokens)))
                    kvCache = reuseCache
                } else if !skipReuse, commonLen == promptTokenIds.count {
                    // Same prompt as the previous call: the cache holds the
                    // prompt plus stale generations. Trim back to promptLen - K
                    // and re-prefill the last K tokens (identical K/V) so
                    // continuation decode runs from the warm cache — the
                    // variant-decode path, cheaper than a full re-prefill.
                    let targetLen = max(0, promptTokenIds.count - Self.variantTrimBackTokens)
                    for cache in reuseCache {
                        let backTrim = cache.offset - targetLen
                        if backTrim > 0 {
                            _ = cache.trim(backTrim)
                        }
                    }
                    if targetLen > 0 {
                        let suffixTokens = Array(promptTokenIds[targetLen...])
                        effectiveInput = LMInput(text: LMInput.Text(tokens: MLXArray(suffixTokens)))
                        kvCache = reuseCache
                    } else {
                        kvCache = nil
                    }
                }
            }
        }

        if kvCache == nil {
            kvCache = context.model.newCache(parameters: parameters)
        }
        return (kvCache, effectiveInput)
    }

    nonisolated static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] != b[i] { return i }
        }
        return minLen
    }

    func generateStream(
        prefix: String,
        suffix: String,
        maxTokens: Int = 64,
        temperature: Float = 0.1,
        topP: Float = 0.9,
        repetitionPenalty: Float = 1.1,
        bannedTokenIDs: [Int] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [self] continuation in
            let task = Task {
                do {
                    // Serialize with the chat engine — concurrent MLX streams
                    // thrash the shared allocator (see MLXInferenceLock).
                    await MLXInferenceLock.shared.acquire()
                    defer { Task { await MLXInferenceLock.shared.release() } }
                    let container = try await ensureLoaded()
                    guard LocalModelCatalog.model(id: modelId) != nil else {
                        continuation.finish(throwing: AppError.aiServiceError("Completion model not found: \(modelId)"))
                        return
                    }
                    // Fixed FIM model (Qwen2.5-Coder-1.5B) — tokens and context
                    // are constants, no per-model branching.
                    let fimTokens = FIMTokens.qwen25Coder
                    let contextLength = 4096
                    var effectivePrefix = prefix
                    var effectiveSuffix = suffix
                    truncateInput(prefix: &effectivePrefix, suffix: &effectiveSuffix, contextLength: contextLength, maxTokens: maxTokens)

                    let prompt = "\(fimTokens.prefix)\(effectivePrefix)\(fimTokens.suffix)\(effectiveSuffix)\(fimTokens.middle)"

                     let parameters = GenerateParameters(
                         maxTokens: min(maxTokens, 512),
                         maxKVSize: contextLength,
                         // kvBits intentionally omitted: the FIM model uses a rotating KV cache,
                    // which mlx-swift does not quantize — the flag was a silent no-op.
                    kvBits: 0,
                         temperature: temperature,
                         topP: topP,
                         repetitionPenalty: repetitionPenalty,
                         repetitionContextSize: 20,
                         prefillStepSize: 512
                     )

                    let tokenizer = await container.tokenizer
                    let tokenIds = tokenizer.encode(text: prompt, addSpecialTokens: true)
                    let fullInput = LMInput(text: LMInput.Text(tokens: MLXArray(tokenIds)))

                    // KV-cache reuse: prefill the full prompt once, then only
                    // the delta after the common prefix is re-encoded on the
                    // next call (per-keystroke cost ~= suffix tail + decode).
                    let cachedTokens = cachedPromptTokens
                    let cachedCache = kvCache
                    let prevCachedOffset = cachedOffset
                    let stateBox = GenerationStateBox()
                    let stream = try await container.perform { context in
                        let (cache, effectiveInput) = try Self.resolveKVCache(
                            input: fullInput,
                            cachedTokens: cachedTokens,
                            cachedCache: cachedCache,
                            cachedOffset: prevCachedOffset,
                            promptTokenIds: tokenIds,
                            parameters: parameters,
                            context: context
                        )
                        stateBox.cache = cache
                        // Custom processor: hard-banned first tokens (variant
                        // exclusion) composed with the standard repetition
                        // processor; also captures the first sampled token ID.
                        let processor = FIMBannedTokenProcessor(
                            bannedTokenIDs: bannedTokenIDs,
                            upstream: parameters.processor()
                        )
                        let iterator = try TokenIterator(
                            input: effectiveInput,
                            model: context.model,
                            cache: cache,
                            processor: processor,
                            sampler: parameters.sampler(),
                            prefillStepSize: parameters.prefillStepSize,
                            maxTokens: parameters.maxTokens
                        )
                        let (generationStream, _) = MLXLMCommon.generateTask(
                            promptTokenCount: effectiveInput.text.tokens.size,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator
                        )
                        stateBox.processor = processor
                        return generationStream
                    }

                    for await generation in stream {
                        if Task.isCancelled { break }
                        if case .chunk(let text) = generation, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    // Keep the warm cache + prompt tokens for the next call.
                    kvCache = stateBox.cache
                    cachedPromptTokens = tokenIds
                    cachedOffset = stateBox.cache?.first?.offset ?? tokenIds.count
                    lastGeneratedFirstTokenID = stateBox.processor?.firstTokenID
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            generationTask = task
            continuation.onTermination = { _ in
                // Cancel the captured task directly — avoids the race where
                // generationTask has already been reassigned by a newer call.
                task.cancel()
            }
        }
    }
}