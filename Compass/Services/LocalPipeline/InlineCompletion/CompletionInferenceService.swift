import Foundation

protocol OfflineModeChecking: Sendable {
    func isOfflineModeEnabled() async -> Bool
}

extension LocalModelSelectionStore: OfflineModeChecking {}

@MainActor
protocol InlineCompletionProviding {
    func complete(
        prompt: String,
        triggerReason: CompletionTriggerReason,
        routingMode: InlineCompletionRoutingMode
    ) async throws -> (text: String, source: InlineCompletionSource)?

    func completeLocally(
        prefix: String,
        suffix: String,
        maxTokens: Int
    ) async throws -> (text: String, source: InlineCompletionSource)?

    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<String, Error>?
}

extension InlineCompletionProviding {
    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<String, Error>? {
        nil
    }
}

@MainActor
final class AIServiceInlineCompletionProvider: InlineCompletionProviding {
    private let aiServiceProvider: () -> AIService?
    private let remoteServiceProvider: (@Sendable () async -> AIService?)?
    private let localServiceProvider: (@Sendable () async -> AIService?)?
    private let offlineModeChecker: OfflineModeChecking
    private let localModelSelectionStore: LocalModelSelectionStore?
    private var fimService: FIMInferenceService?

    init(
        aiServiceProvider: @escaping () -> AIService?,
        offlineModeChecker: OfflineModeChecking = LocalModelSelectionStore()
    ) {
        self.aiServiceProvider = aiServiceProvider
        self.remoteServiceProvider = nil
        self.localServiceProvider = nil
        self.offlineModeChecker = offlineModeChecker
        self.localModelSelectionStore = nil
        registerForPressureUnload()
    }

    init(
        remoteServiceProvider: @escaping @Sendable () async -> AIService?,
        localServiceProvider: @escaping @Sendable () async -> AIService?,
        localModelSelectionStore: LocalModelSelectionStore,
        offlineModeChecker: OfflineModeChecking? = nil
    ) {
        self.aiServiceProvider = { nil }
        self.remoteServiceProvider = remoteServiceProvider
        self.localServiceProvider = localServiceProvider
        self.localModelSelectionStore = localModelSelectionStore
        self.offlineModeChecker = offlineModeChecker ?? localModelSelectionStore
    }

    func complete(
        prompt: String,
        triggerReason: CompletionTriggerReason,
        routingMode: InlineCompletionRoutingMode
    ) async throws -> (text: String, source: InlineCompletionSource)? {
        let offlineMode = await offlineModeChecker.isOfflineModeEnabled()

        switch routingMode {
        case .localOnly:
            let service = await localServiceProvider?() ?? aiServiceProvider()
            return try await completeWith(service: service, source: .local, prompt: prompt)
        case .remoteOnly:
            guard !offlineMode else { return nil }
            let service = await remoteServiceProvider?() ?? aiServiceProvider()
            return try await completeWith(service: service, source: .remote, prompt: prompt)
        case .hybridPreferLocal, .hybridPreferRemote:
            return nil
        }
    }

    private func completeWith(
        service: AIService?,
        source: InlineCompletionSource,
        prompt: String
    ) async throws -> (text: String, source: InlineCompletionSource)? {
        guard let service else { return nil }

        let text = try await service.generateCode(prompt)
        return (text, source)
    }

    func completeLocallyStreaming(
        prefix: String,
        suffix: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<String, Error>? {
        let modelId = LocalModelCatalog.fimModel.id

        guard let model = LocalModelCatalog.model(id: modelId),
              LocalModelFileStore.isModelInstalled(model) else {
            return nil
        }

        let service = try await resolveFIMService(modelId: modelId)
        return await service.generateStream(prefix: prefix, suffix: suffix, maxTokens: maxTokens)
    }

    func completeLocally(
        prefix: String,
        suffix: String,
        maxTokens: Int
    ) async throws -> (text: String, source: InlineCompletionSource)? {
        try Task.checkCancellation()
        let modelId = LocalModelCatalog.fimModel.id

        guard let model = LocalModelCatalog.model(id: modelId) else {
            await AppLogger.shared.warning(
                category: .ai,
                message: "inline_completion.fim_model_not_in_catalog",
                context: AppLogger.LogCallContext(metadata: ["modelId": modelId])
            )
            return nil
        }

        guard LocalModelFileStore.isModelInstalled(model) else {
            await AppLogger.shared.warning(
                category: .ai,
                message: "inline_completion.fim_model_not_installed",
                context: AppLogger.LogCallContext(metadata: [
                    "modelId": modelId,
                    "displayName": model.displayName
                ])
            )
            return nil
        }

        do {
            let service = try await resolveFIMService(modelId: modelId)
            let text = try await service.generate(prefix: prefix, suffix: suffix, maxTokens: maxTokens)
            guard !text.isEmpty else { return nil }
            return (text, .local)
        } catch {
            await AppLogger.shared.warning(
                category: .ai,
                message: "inline_completion.fim_generation_error",
                context: AppLogger.LogCallContext(metadata: [
                    "modelId": modelId,
                    "error": String(describing: error)
                ])
            )
            return nil
        }
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

@MainActor
protocol CompletionInferring {
    func infer(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> InlineCompletionResult?

    func inferStreaming(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> AsyncThrowingStream<String, Error>?
}

extension CompletionInferring {
    func inferStreaming(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> AsyncThrowingStream<String, Error>? {
        nil
    }
}

@MainActor
final class CompletionInferenceService: CompletionInferring {
    private let provider: InlineCompletionProviding

    init(provider: InlineCompletionProviding) {
        self.provider = provider
    }

    func infer(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> InlineCompletionResult? {
        let startedAt = Date()

        let source: InlineCompletionSource
        let text: String

        let result: (text: String, source: InlineCompletionSource)? = try await routeInference(
            for: request, settings: settings
        )

        guard let result else { return nil }
        text = result.text; source = result.source

        return InlineCompletionResult(
            requestId: request.requestId,
            suggestionText: text,
            confidenceScore: 0.5,
            source: source,
            latencyMs: Date().timeIntervalSince(startedAt) * 1_000
        )
    }

    func inferStreaming(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> AsyncThrowingStream<String, Error>? {
        switch settings.routingMode {
        case .localOnly, .hybridPreferLocal:
            return try await provider.completeLocallyStreaming(
                prefix: request.prefix, suffix: request.suffix, maxTokens: request.maxTokens
            )
        case .remoteOnly, .hybridPreferRemote:
            return nil
        }
    }

    private func routeInference(
        for request: InlineCompletionRequest,
        settings: InlineCompletionSettings
    ) async throws -> (text: String, source: InlineCompletionSource)? {
        switch settings.routingMode {
        case .localOnly:
            return try await attemptLocal(request: request)

        case .remoteOnly:
            return try await attemptRemote(request: request)

        case .hybridPreferLocal:
            if let local = try? await attemptLocal(request: request) {
                return local
            }
            await AppLogger.shared.debug(
                category: .ai,
                message: "inline_completion.local_failed_falling_back_remote",
                context: AppLogger.LogCallContext(metadata: [
                    "requestId": request.requestId.uuidString
                ])
            )
            return try await attemptRemote(request: request)

        case .hybridPreferRemote:
            if let remote = try? await attemptRemote(request: request) {
                return remote
            }
            await AppLogger.shared.debug(
                category: .ai,
                message: "inline_completion.remote_failed_falling_back_local",
                context: AppLogger.LogCallContext(metadata: [
                    "requestId": request.requestId.uuidString
                ])
            )
            return try await attemptLocal(request: request)
        }
    }

    private func attemptLocal(request: InlineCompletionRequest) async throws -> (text: String, source: InlineCompletionSource)? {
        do {
            guard let result = try await provider.completeLocally(
                prefix: request.prefix, suffix: request.suffix, maxTokens: request.maxSuggestionLength
            ) else { return nil }
            return result
        } catch {
            await AppLogger.shared.warning(
                category: .ai,
                message: "inline_completion.local_inference_error",
                context: AppLogger.LogCallContext(metadata: [
                    "requestId": request.requestId.uuidString,
                    "error": String(describing: error),
                    "language": request.language
                ])
            )
            return nil
        }
    }

    private func attemptRemote(request: InlineCompletionRequest) async throws -> (text: String, source: InlineCompletionSource)? {
        do {
            let prompt = makePrompt(for: request)
            guard let result = try await provider.complete(prompt: prompt, triggerReason: request.triggerReason, routingMode: .remoteOnly) else {
                return nil
            }
            return result
        } catch {
            await AppLogger.shared.warning(
                category: .ai,
                message: "inline_completion.remote_inference_error",
                context: AppLogger.LogCallContext(metadata: [
                    "requestId": request.requestId.uuidString,
                    "error": String(describing: error),
                    "language": request.language
                ])
            )
            return nil
        }
    }

    private func makePrompt(for request: InlineCompletionRequest) -> String {
        var parts: [String] = [
            "You are generating inline code completion for a native macOS IDE.",
            "Return only the code that should be inserted at the cursor.",
            "Do not explain. Do not use markdown. Prefer a short, likely continuation."
        ]

        parts.append("Language: \(request.language)")
        if let filePath = request.filePath {
            parts.append("File: \(filePath)")
        }
        if let scopeSummary = request.scopeSummary {
            parts.append("Scope: \(scopeSummary)")
        }
        if !request.symbols.isEmpty {
            parts.append("Nearby symbols: \(request.symbols.joined(separator: ", "))")
        }
        if !request.retrievalContext.isEmpty {
            parts.append("Retrieved context:\n\(request.retrievalContext.joined(separator: "\n"))")
        }

        parts.append("Before cursor:\n\(request.prefix)")
        parts.append("After cursor:\n\(request.suffix)")
        parts.append("Constraints: max \(request.maxSuggestionLength) characters; multiline \(request.allowMultiline ? "allowed" : "disallowed").")
        return parts.joined(separator: "\n\n")
    }
}
