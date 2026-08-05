import Foundation

@MainActor
final class LineCompletionEngine {
    typealias SuggestionHandler = @MainActor (InlineSuggestionPresentation?) -> Void

    /// Single source of truth for the output token budget (FIM_Spec.md §4).
    static let maxTokens = 64

    /// Adaptive budget ladder (FIM_Spec.md §5): the faster the typing, the
    /// fewer tokens per call — measured per-keystroke cost at 4 tokens ≈ 200ms
    /// with KV reuse, 16 tokens ≈ 350ms, 64 ≈ 900ms.
    static let pauseThresholdMs: Double = 300
    static let tokenBudgetByGapMs: [(gapMs: Double, tokens: Int)] = [
        (200, 16),
        (100, 8),
        (0, 4)
    ]

    private let inferenceService: CompletionInferring
    private let settingsStore: InlineCompletionSettingsStore
    private let gate: LineCompletionGate
    private let contextAssembler: LineCompletionContextAssembler
    private let ranker: LineCompletionRanker
    private let resultCache: LineCompletionResultCache
    private let telemetryService: CompletionTelemetryService
    private let variantPoolService: VariantPoolService?

    private var suggestionHandlers: [FileEditorStateManager.PaneID: SuggestionHandler] = [:]
    private var activeRequestIDs: [FileEditorStateManager.PaneID: UUID] = [:]
    private var requestTasks: [FileEditorStateManager.PaneID: Task<Void, Never>] = [:]
    private var lastAcceptedSuggestions: [FileEditorStateManager.PaneID: String] = [:]
    private var lastAcceptedAt: [FileEditorStateManager.PaneID: Date] = [:]
    private var recentRejections: [FileEditorStateManager.PaneID: Int] = [:]
    private var lastShownSuggestion: [FileEditorStateManager.PaneID: String] = [:]
    private var lastShownAt: [FileEditorStateManager.PaneID: Date] = [:]
    private var lastBufferBeforeCursor: [FileEditorStateManager.PaneID: String] = [:]
    private var lastPoolPublishAt: [FileEditorStateManager.PaneID: Date] = [:]

    /// Window (ms) in which a typed character that extends the shown
    /// suggestion's head is consumed without a model call (accept-verify).
    private let acceptVerifyWindowMs: Double = 500

    /// Adaptive output budget: pause → full budget; faster typing → fewer
    /// tokens (FIM_Spec.md §5).
    private func adaptiveMaxTokens(gapMs: Double) -> Int {
        if gapMs >= Self.pauseThresholdMs { return Self.maxTokens }
        for entry in Self.tokenBudgetByGapMs where gapMs >= entry.gapMs {
            return entry.tokens
        }
        return 4
    }

    init(
        inferenceService: CompletionInferring,
        settingsStore: InlineCompletionSettingsStore = InlineCompletionSettingsStore(),
        gate: LineCompletionGate = LineCompletionGate(),
        contextAssembler: LineCompletionContextAssembler = LineCompletionContextAssembler(),
        ranker: LineCompletionRanker = LineCompletionRanker(),
        resultCache: LineCompletionResultCache = LineCompletionResultCache(),
        telemetryService: CompletionTelemetryService = CompletionTelemetryService(),
        variantPoolService: VariantPoolService? = nil
    ) {
        self.inferenceService = inferenceService
        self.settingsStore = settingsStore
        self.gate = gate
        self.contextAssembler = contextAssembler
        self.ranker = ranker
        self.resultCache = resultCache
        self.telemetryService = telemetryService
        self.variantPoolService = variantPoolService
        variantPoolService?.onVariantsChanged = { [weak self] paneID in
            self?.poolVariantsChanged(paneID: paneID)
        }
    }

    func registerSuggestionHandler(for paneID: FileEditorStateManager.PaneID, handler: @escaping SuggestionHandler) {
        suggestionHandlers[paneID] = handler
    }

    /// The pane's variant-pool alternatives (best-first) for the dropdown
    /// (FIM_VariantPools_Arch.md §5). Empty when no pool exists.
    func poolVariants(for paneID: FileEditorStateManager.PaneID) async -> [InlineCompletionVariant] {
        await variantPoolService?.variants(paneID: paneID) ?? []
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

            let bufferBeforeCursor = String(snapshot.buffer.prefix(snapshot.cursorPosition))
            self.lastBufferBeforeCursor[snapshot.paneID] = bufferBeforeCursor

            // Pool consumption (accept-verify generalized over the variant
            // pool): serve the best variant whose head the buffer extends —
            // no model call. Runs BEFORE the gate so fast typing never clears
            // the ghost while the suggestion is being consumed. A miss here
            // is the deviation signal.
            var hadSuggestionContext = false
            if let poolService = self.variantPoolService,
               let pool = await poolService.activePool(paneID: snapshot.paneID, bufferBeforeCursor: bufferBeforeCursor) {
                hadSuggestionContext = true
                let variants = pool.variants.sorted { $0.rankScore > $1.rankScore }
                if self.consumeHead(of: variants, bufferBeforeCursor: bufferBeforeCursor, paneID: snapshot.paneID) {
                    return
                }
            } else {
                // Pre-pool accept-verify: the buffer's tail extends the shown
                // suggestion's head — consume it without a model call.
                if let lastShown = self.lastShownSuggestion[snapshot.paneID],
                   !lastShown.isEmpty,
                   let shownAt = self.lastShownAt[snapshot.paneID],
                   Date().timeIntervalSince(shownAt) * 1000 < self.acceptVerifyWindowMs {
                    hadSuggestionContext = true
                    if self.consumeHead(of: [InlineCompletionVariant(
                        id: UUID(), text: lastShown, temperature: 0.1,
                        bannedTokenCount: 0, createdAt: Date(), rankScore: 1
                    )], bufferBeforeCursor: bufferBeforeCursor, paneID: snapshot.paneID) {
                        return
                    }
                }
            }

            // The context moved (any request supersedes the running chain —
            // it would keep appending stale variants for the old context).
            if let poolService = self.variantPoolService {
                await poolService.cancelChain(paneID: snapshot.paneID)
            }

            let rejectCount = self.recentRejections[snapshot.paneID] ?? 0
            guard self.gate.shouldRequest(
                for: snapshot, settings: settings,
                gapMs: gapMs, typedChar: typedChar, recentRejectionCount: rejectCount
            ) else {
                self.publish(nil, for: snapshot.paneID)
                return
            }

            if let cached = await self.resultCache.lookup(prefix: snapshot.buffer.prefix(snapshot.cursorPosition).suffix(100).description, suffix: snapshot.buffer.dropFirst(snapshot.cursorPosition).prefix(100).description) {
                self.publish(cached, for: snapshot.paneID)
                return
            }

            let context = self.contextAssembler.buildContext(from: snapshot)
            let request = InlineCompletionRequest(
                requestId: requestID,
                language: snapshot.language,
                prefix: context.prefix,
                suffix: context.suffix,
                triggerReason: snapshot.triggerReason,
                maxSuggestionLength: settings.maxSuggestionLength,
                maxTokens: self.adaptiveMaxTokens(gapMs: gapMs),
                bannedTokenIDs: [],
                variantTemperature: nil
            )

            do {
                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.generating)

                guard let stream = try await self.inferenceService.inferStreaming(for: request, settings: settings) else {
                    self.publish(nil, for: snapshot.paneID)
                    NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.noSuggestion)
                    return
                }
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
                let result: InlineCompletionResult? = accumulated.isEmpty ? nil : InlineCompletionResult(
                    requestId: requestID, suggestionText: accumulated,
                    confidenceScore: 0.5, source: .local, latencyMs: 0
                )
                if let final = result {
                    // Cache keys must match the lookup window (last 100 chars
                    // of prefix, first 100 of suffix) — previously the store
                    // used the full assembler prefix, so lookups never hit.
                    await self.resultCache.store(
                        InlineSuggestionPresentation(requestId: final.requestId, suggestionText: final.suggestionText, source: final.source, confidenceScore: final.confidenceScore, latencyMs: final.latencyMs),
                        prefix: String(context.prefix.suffix(100)),
                        suffix: String(context.suffix.prefix(100))
                    )
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
                    // The user keeps rejecting the top variant — promote the
                    // second-best as the auto-suggestion.
                    if let poolService = self.variantPoolService {
                        await poolService.demoteTop(paneID: snapshot.paneID)
                    }
                }

                // The user deviated from a shown suggestion — seed the variant
                // pool with this prediction and chain the alternatives.
                if hadSuggestionContext, let poolService = self.variantPoolService {
                    let firstToken = await self.inferenceService.lastGeneratedFirstTokenID()
                    await poolService.registerDeviation(
                        paneID: snapshot.paneID,
                        bufferBeforeCursor: bufferBeforeCursor,
                        cursor: snapshot.cursorPosition,
                        prefix: context.prefix,
                        suffix: context.suffix,
                        maxTokens: request.maxTokens,
                        seededVariantText: result.suggestionText,
                        seededFirstTokenID: firstToken
                    )
                }

                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.idle)
            } catch {
                self.publish(nil, for: snapshot.paneID)
            }
        }
    }

    /// Publishes the remainder of the best variant whose head the buffer
    /// extends. Returns true when consumed (no model call needed).
    private func consumeHead(of variants: [InlineCompletionVariant], bufferBeforeCursor: String, paneID: FileEditorStateManager.PaneID) -> Bool {
        for variant in variants where !variant.text.isEmpty {
            let maxHeadLen = min(variant.text.count, 60)
            if maxHeadLen <= 0 { continue }
            var consumed: Int?
            for headLen in stride(from: maxHeadLen, through: 1, by: -1) {
                if bufferBeforeCursor.hasSuffix(variant.text.prefix(headLen)) {
                    consumed = headLen
                    break
                }
            }
            if let consumed {
                let remaining = String(variant.text.dropFirst(consumed))
                if remaining.isEmpty {
                    self.publish(nil, for: paneID)
                } else {
                    self.publish(InlineSuggestionPresentation(
                        requestId: UUID(), suggestionText: remaining,
                        source: .local, confidenceScore: 0.5, latencyMs: 0
                    ), for: paneID)
                }
                return true
            }
        }
        return false
    }

    /// The chain appended variants — re-publish the pool's new top suggestion
    /// if it changed (throttled to avoid ghost flicker).
    nonisolated private func poolVariantsChanged(paneID: FileEditorStateManager.PaneID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastPoolPublishAt[paneID],
               now.timeIntervalSince(last) * 1000 < 150 {
                return
            }
            guard let poolService = self.variantPoolService,
                  let buffer = self.lastBufferBeforeCursor[paneID],
                  let pool = await poolService.activePool(paneID: paneID, bufferBeforeCursor: buffer),
                  let top = pool.variants.sorted(by: { $0.rankScore > $1.rankScore }).first else {
                return
            }
            self.lastPoolPublishAt[paneID] = now
            if top.text != self.lastShownSuggestion[paneID] {
                self.publish(InlineSuggestionPresentation(
                    requestId: UUID(), suggestionText: top.text,
                    source: .local, confidenceScore: 0.5, latencyMs: 0
                ), for: paneID)
            }
        }
    }

    func invalidate(_ paneID: FileEditorStateManager.PaneID) {
        requestTasks[paneID]?.cancel()
        requestTasks[paneID] = nil
        activeRequestIDs.removeValue(forKey: paneID)
        lastShownSuggestion.removeValue(forKey: paneID)
        lastShownAt.removeValue(forKey: paneID)
        lastPoolPublishAt.removeValue(forKey: paneID)
        if let poolService = variantPoolService {
            Task { await poolService.reset(paneID: paneID) }
        }
        publish(nil, for: paneID)
        Task { await telemetryService.recordCancelled() }
    }

    func markAccepted(on paneID: FileEditorStateManager.PaneID, suggestionText: String?) {
        if let suggestionText, !suggestionText.isEmpty {
            lastAcceptedSuggestions[paneID] = suggestionText
            lastAcceptedAt[paneID] = Date()
            lastShownSuggestion[paneID] = suggestionText
            lastShownAt[paneID] = Date()
        }
        Task { await telemetryService.recordAccepted() }
    }

    func markDismissed() {
        lastShownSuggestion.removeAll()
        lastShownAt.removeAll()
        Task { await telemetryService.recordDismissed() }
    }

    private func publish(_ presentation: InlineSuggestionPresentation?, for paneID: FileEditorStateManager.PaneID) {
        if let presentation {
            lastShownSuggestion[paneID] = presentation.suggestionText
            lastShownAt[paneID] = Date()
        }
        suggestionHandlers[paneID]?(presentation)
    }
}
