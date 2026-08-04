import Foundation

@MainActor
final class LineCompletionEngine {
    typealias SuggestionHandler = @MainActor (InlineSuggestionPresentation?) -> Void

    private let inferenceService: CompletionInferring
    private let settingsStore: InlineCompletionSettingsStore
    private let triggerPolicy: CompletionTriggerPolicy
    private let contextAssembler: LineCompletionContextAssembler
    private let contextualFilter: LineCompletionContextualFilter
    private let ranker: LineCompletionRanker
    private let resultCache: LineCompletionResultCache
    private let telemetryService: CompletionTelemetryService

    private var suggestionHandlers: [FileEditorStateManager.PaneID: SuggestionHandler] = [:]
    private var activeRequestIDs: [FileEditorStateManager.PaneID: UUID] = [:]
    private var requestTasks: [FileEditorStateManager.PaneID: Task<Void, Never>] = [:]
    private var lastAcceptedSuggestions: [FileEditorStateManager.PaneID: String] = [:]
    private var lastAcceptedAt: [FileEditorStateManager.PaneID: Date] = [:]
    private var recentRejections: [FileEditorStateManager.PaneID: Int] = [:]

    private let automaticAcceptanceCooldownMs: Double = 100

    init(
        inferenceService: CompletionInferring,
        settingsStore: InlineCompletionSettingsStore = InlineCompletionSettingsStore(),
        triggerPolicy: CompletionTriggerPolicy = CompletionTriggerPolicy(),
        contextAssembler: LineCompletionContextAssembler = LineCompletionContextAssembler(),
        contextualFilter: LineCompletionContextualFilter = LineCompletionContextualFilter(),
        ranker: LineCompletionRanker = LineCompletionRanker(),
        resultCache: LineCompletionResultCache = LineCompletionResultCache(),
        telemetryService: CompletionTelemetryService = CompletionTelemetryService()
    ) {
        self.inferenceService = inferenceService
        self.settingsStore = settingsStore
        self.triggerPolicy = triggerPolicy
        self.contextAssembler = contextAssembler
        self.contextualFilter = contextualFilter
        self.ranker = ranker
        self.resultCache = resultCache
        self.telemetryService = telemetryService
    }

    func registerSuggestionHandler(for paneID: FileEditorStateManager.PaneID, handler: @escaping SuggestionHandler) {
        suggestionHandlers[paneID] = handler
    }

    func unregisterSuggestionHandler(for paneID: FileEditorStateManager.PaneID) {
        suggestionHandlers.removeValue(forKey: paneID)
    }

    func requestCompletion(for snapshot: InlineCompletionEditorSnapshot, gapMs: Double = 0, typedChar: Character? = nil) {
        requestTasks[snapshot.paneID]?.cancel()

        let requestID = UUID()
        activeRequestIDs[snapshot.paneID] = requestID
        let settings = settingsStore.load()

        requestTasks[snapshot.paneID] = Task { [weak self] in
            guard let self else { return }

            guard settings.isEnabled else {
                self.publish(nil, for: snapshot.paneID)
                return
            }

            guard self.triggerPolicy.shouldRequest(for: snapshot, settings: settings) else {
                self.publish(nil, for: snapshot.paneID)
                return
            }

            let rejectCount = self.recentRejections[snapshot.paneID] ?? 0
            guard self.contextualFilter.shouldRequest(for: snapshot, gapMs: gapMs, typedChar: typedChar, recentRejectionCount: rejectCount) else {
                self.publish(nil, for: snapshot.paneID)
                return
            }

            if snapshot.triggerReason == .automatic,
               let acceptedAt = self.lastAcceptedAt[snapshot.paneID],
               let lastText = self.lastAcceptedSuggestions[snapshot.paneID],
               Date().timeIntervalSince(acceptedAt) * 1000 < self.automaticAcceptanceCooldownMs {
                let bufferBeforeCursor = snapshot.buffer.prefix(snapshot.cursorPosition)
                let bufferAfterCursor = snapshot.buffer.dropFirst(snapshot.cursorPosition).prefix(lastText.count)
                if !bufferAfterCursor.isEmpty, bufferAfterCursor == lastText.prefix(bufferAfterCursor.count) {
                    self.publish(nil, for: snapshot.paneID)
                    return
                }
                if bufferBeforeCursor.hasSuffix(lastText) {
                    self.publish(nil, for: snapshot.paneID)
                    return
                }
            }

            if let cached = await self.resultCache.lookup(prefix: snapshot.buffer.prefix(snapshot.cursorPosition).suffix(100).description, suffix: snapshot.buffer.dropFirst(snapshot.cursorPosition).prefix(100).description) {
                self.publish(cached, for: snapshot.paneID)
                return
            }

            let context = self.contextAssembler.buildContext(from: snapshot)
            let maxTokens = 24
            let request = InlineCompletionRequest(
                requestId: requestID,
                filePath: snapshot.filePath,
                language: snapshot.language,
                prefix: context.prefix,
                suffix: context.suffix,
                cursorPosition: snapshot.cursorPosition,
                scopeSummary: context.scopeSummary,
                symbols: [],
                retrievalContext: [],
                triggerReason: snapshot.triggerReason,
                maxSuggestionLength: settings.maxSuggestionLength,
                maxTokens: maxTokens,
                allowMultiline: false
            )

            do {
                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.generating)

                let result: InlineCompletionResult?

                if let stream = try await self.inferenceService.inferStreaming(for: request, settings: settings) {
                    var accumulated = ""
                    var latestAccepted: InlineSuggestionPresentation?
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        accumulated.append(chunk)
                        if accumulated.contains("\n") { break }
                        let partial = InlineCompletionResult(
                            requestId: requestID,
                            suggestionText: accumulated,
                            confidenceScore: 0.5,
                            source: .local,
                            latencyMs: 0
                        )
                        if let candidate = self.ranker.rank(partial, for: request, aggressiveness: settings.aggressiveness) {
                            latestAccepted = candidate
                            self.publish(candidate, for: snapshot.paneID)
                        }
                    }
                    result = accumulated.isEmpty ? nil : InlineCompletionResult(
                        requestId: requestID, suggestionText: accumulated,
                        confidenceScore: 0.5, source: .local, latencyMs: 0
                    )
                    if let final = result {
                        await self.resultCache.store(
                            InlineSuggestionPresentation(requestId: final.requestId, suggestionText: final.suggestionText, source: final.source, confidenceScore: final.confidenceScore, latencyMs: final.latencyMs),
                            prefix: context.prefix, suffix: context.suffix
                        )
                    }
                } else {
                    result = try await self.inferenceService.infer(for: request, settings: settings)
                }

                guard let result else {
                    self.publish(nil, for: snapshot.paneID)
                    NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.noSuggestion)
                    return
                }

                guard !Task.isCancelled else { return }
                guard self.activeRequestIDs[snapshot.paneID] == requestID else { return }

                await self.telemetryService.recordObservedLatency(result.latencyMs)

                let evaluation = self.ranker.evaluate(result, for: request, aggressiveness: settings.aggressiveness)
                switch evaluation {
                case .accepted(let candidate):
                    if let lastAccepted = self.lastAcceptedSuggestions[snapshot.paneID],
                       candidate.suggestionText == lastAccepted {
                        self.publish(nil, for: snapshot.paneID)
                    } else {
                        self.recentRejections[snapshot.paneID] = 0
                        await self.telemetryService.recordShown(candidate)
                        self.publish(candidate, for: snapshot.paneID)
                    }
                case .rejected:
                    self.recentRejections[snapshot.paneID] = (self.recentRejections[snapshot.paneID] ?? 0) + 1
                    self.publish(nil, for: snapshot.paneID)
                }

                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.idle)
            } catch {
                self.publish(nil, for: snapshot.paneID)
            }
        }
    }

    func invalidate(_ paneID: FileEditorStateManager.PaneID) {
        requestTasks[paneID]?.cancel()
        requestTasks[paneID] = nil
        activeRequestIDs.removeValue(forKey: paneID)
        publish(nil, for: paneID)
        Task { await telemetryService.recordCancelled() }
    }

    func markAccepted(on paneID: FileEditorStateManager.PaneID, suggestionText: String?) {
        if let suggestionText, !suggestionText.isEmpty {
            lastAcceptedSuggestions[paneID] = suggestionText
            lastAcceptedAt[paneID] = Date()
        }
        Task { await telemetryService.recordAccepted() }
    }

    func markDismissed() {
        Task { await telemetryService.recordDismissed() }
    }

    private func publish(_ presentation: InlineSuggestionPresentation?, for paneID: FileEditorStateManager.PaneID) {
        suggestionHandlers[paneID]?(presentation)
    }
}
