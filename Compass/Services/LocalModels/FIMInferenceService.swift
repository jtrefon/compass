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
        modelContainer = nil
    }

    func generate(prefix: String, suffix: String, maxTokens: Int = 64) async throws -> String {
        try Task.checkCancellation()
        var output = ""
        for try await chunk in generateStream(prefix: prefix, suffix: suffix, maxTokens: maxTokens) {
            output.append(chunk)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let maxPrefixChars = maxChars - maxSuffixChars

        if suffix.count > maxSuffixChars {
            suffix = String(suffix.prefix(maxSuffixChars))
        }
        if prefix.count > maxChars - suffix.count {
            prefix = String(prefix.suffix(maxChars - suffix.count))
        }
    }

    func generateStream(
        prefix: String,
        suffix: String,
        maxTokens: Int = 64
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
                         temperature: 0.1,
                         topP: 0.9,
                         repetitionPenalty: 1.1,
                         repetitionContextSize: 20,
                         prefillStepSize: 512
                     )

                    let tokenizer = await container.tokenizer
                    let tokenIds = tokenizer.encode(text: prompt, addSpecialTokens: true)
                    let input = LMInput(text: LMInput.Text(tokens: MLXArray(tokenIds)))

                    let stream = try await container.generate(input: input, parameters: parameters)
                    for await generation in stream {
                        if Task.isCancelled { break }
                        if case .chunk(let text) = generation, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
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