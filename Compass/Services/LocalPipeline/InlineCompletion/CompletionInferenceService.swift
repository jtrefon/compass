import Foundation

// MARK: - Inline completion provider (local FIM only, per FIM_Spec.md)

/// Contract for local inline completion. The product is local-only
/// (FIM_Spec.md §2): no remote/cloud path, no routing modes, fixed model.
@MainActor
protocol InlineCompletionProviding: Sendable {
    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int,
        bannedTokenIDs: [Int],
        variantTemperature: Float?
    ) async throws -> AsyncThrowingStream<String, Error>?

    /// First token ID of the most recent generation — the ban set builder for
    /// the next variant (FIM_VariantPools_Arch.md §4).
    func lastGeneratedFirstTokenID() async -> Int?
}

/// Resolves the fixed FIM model (Qwen2.5-Coder-1.5B-Instruct-4bit) and streams
/// single-line completions. There is deliberately no user model selection and
/// no remote fallback — a missing model simply yields `nil`.
@MainActor
final class AIServiceInlineCompletionProvider: InlineCompletionProviding {
    private var fimService: FIMInferenceService?

    init() {
        registerForPressureUnload()
    }

    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int,
        bannedTokenIDs: [Int] = [],
        variantTemperature: Float? = nil
    ) async throws -> AsyncThrowingStream<String, Error>? {
        let modelId = LocalModelCatalog.fimModel.id

        guard let model = LocalModelCatalog.model(id: modelId),
              LocalModelFileStore.isModelInstalled(model) else {
            return nil
        }

        let service = try await resolveFIMService(modelId: modelId)
        return await service.generateStream(
            prefix: prefix,
            suffix: suffix,
            maxTokens: maxTokens,
            temperature: variantTemperature ?? 0.1,
            bannedTokenIDs: bannedTokenIDs
        )
    }

    func lastGeneratedFirstTokenID() async -> Int? {
        await fimService?.lastGeneratedFirstTokenID
    }

    /// Under memory pressure the chat generator unloads — the FIM container
    /// must too, or the 1GB+ weights keep the process over budget.
    private func registerForPressureUnload() {
        InferenceUnloadRegistry.shared.register { [weak self] in
            if let fim = await MainActor.run(body: { self?.fimService }) {
                await fim.unload()
            }
            await MainActor.run {
                self?.fimService = nil
            }
        }
    }

    private func resolveFIMService(modelId: String) async throws -> FIMInferenceService {
        if let existing = fimService, existing.modelId == modelId {
            return existing
        }
        // Unload the old model before creating a new one to avoid leaking MLX model weights.
        await fimService?.unload()
        let service = try await FIMInferenceService(modelId: modelId)
        fimService = service
        return service
    }
}

// MARK: - Inference service (streaming only)

@MainActor
protocol CompletionInferring {
    func inferStreaming(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> AsyncThrowingStream<String, Error>?

    /// First token ID of the most recent generation — seeds the variant pool's
    /// ban set (FIM_VariantPools_Arch.md §4).
    func lastGeneratedFirstTokenID() async -> Int?
}

extension CompletionInferring {
    func lastGeneratedFirstTokenID() async -> Int? {
        nil
    }
}

@MainActor
final class CompletionInferenceService: CompletionInferring {
    private let provider: InlineCompletionProviding

    init(provider: InlineCompletionProviding) {
        self.provider = provider
    }

    func inferStreaming(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> AsyncThrowingStream<String, Error>? {
        try await provider.completeLocallyStreaming(
            prefix: request.prefix,
            suffix: request.suffix,
            maxTokens: request.maxTokens,
            bannedTokenIDs: request.bannedTokenIDs,
            variantTemperature: request.variantTemperature
        )
    }

    func lastGeneratedFirstTokenID() async -> Int? {
        await provider.lastGeneratedFirstTokenID()
    }
}
