import Foundation

/// Per-pane session state for the completion flow: what was shown, where,
/// and the buffer context used for consumption (accept-verify) and pool
/// re-publishing. One value struct per pane keeps the engine's bookkeeping
/// auditable and testable (no parallel dictionaries).
struct CompletionSessionState {
    var lastShownSuggestion: String?
    var lastShownCursor: Int?
    var lastBufferBeforeCursor: String?
    var lastPoolPublishAt: Date?
}

/// Rate-limits ghost publishes during streaming: the first chunk is published
/// immediately (perceived latency = TTFT), subsequent chunks at most every
/// `minIntervalMs` (the eye cannot track faster — fixes the per-token ghost
/// shake), and the final result on completion.
struct GhostPublishThrottle {
    static let minIntervalMs: Double = 100
    private var lastPublishAt: Date?

    mutating func shouldPublish(force: Bool = false, now: Date = Date()) -> Bool {
        if force { return true }
        guard let last = lastPublishAt else { return true }
        return now.timeIntervalSince(last) * 1000 >= Self.minIntervalMs
    }

    mutating func didPublish(at now: Date = Date()) {
        lastPublishAt = now
    }
}

@MainActor
final class LineCompletionEngine {
    typealias SuggestionHandler = @MainActor (InlineSuggestionPresentation?) -> Void
    typealias PaneID = FileEditorStateManager.PaneID

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
    private let variantPoolService: VariantPoolService?

    private var suggestionHandlers: [PaneID: SuggestionHandler] = [:]
    private var activeRequestIDs: [PaneID: UUID] = [:]
    private var requestTasks: [PaneID: Task<Void, Never>] = [:]
    private var lastAcceptedSuggestions: [PaneID: String] = [:]
    private var lastAcceptedAt: [PaneID: Date] = [:]
    private var recentRejections: [PaneID: Int] = [:]
    private var sessions: [PaneID: CompletionSessionState] = [:]

    /// Fired whenever the variant pool changes (any append) — the coordinator
    /// refreshes the dropdown if open. Event-driven; no polling.
    var onPoolVariantsChanged: (@MainActor (PaneID) -> Void)?

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
        variantPoolService: VariantPoolService? = nil
    ) {
        self.inferenceService = inferenceService
        self.settingsStore = settingsStore
        self.gate = gate
        self.contextAssembler = contextAssembler
        self.ranker = ranker
        self.variantPoolService = variantPoolService
        variantPoolService?.onVariantsChanged = { [weak self] paneID in
            self?.poolVariantsChanged(paneID: paneID)
        }
    }

    func registerSuggestionHandler(for paneID: PaneID, handler: @escaping SuggestionHandler) {
        suggestionHandlers[paneID] = handler
    }

    /// The pane's variant-pool alternatives (best-first) for the dropdown
    /// (FIM_VariantPools_Arch.md §5). Empty when no pool exists.
    func poolVariants(for paneID: PaneID) async -> [InlineCompletionVariant] {
        await variantPoolService?.variants(paneID: paneID) ?? []
    }

    func unregisterSuggestionHandler(for paneID: PaneID) {
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
            self.updateSession(snapshot.paneID) { $0.lastBufferBeforeCursor = bufferBeforeCursor }
            let tail40 = String(bufferBeforeCursor.suffix(40))
            let traceChar = typedChar.map { String($0) } ?? "nil"
            FIMTraceLogger.shared.log("keystroke", [
                "pane": "\(snapshot.paneID)",
                "char": traceChar,
                "gapMs": String(format: "%.0f", gapMs),
                "cursor": "\(snapshot.cursorPosition)",
                "tail": tail40.replacingOccurrences(of: "\n", with: "\\n")
            ])

            // Consumption (accept-verify): serve the best candidate whose head
            // the buffer extends — no model call. Candidates come from the
            // active variant pool, or (pre-pool) the last shown suggestion
            // while the cursor stays on its line (the newline rule — a line
            // break means the context moved). A miss here is the deviation
            // signal. Runs BEFORE the gate so fast typing never clears the
            // ghost while the suggestion is being consumed.
            let session = self.session(for: snapshot.paneID)
            var hadSuggestionContext = false
            var candidates: [InlineCompletionVariant] = []
            var consumptionSource = "lastShown"
            if let poolService = self.variantPoolService,
               let pool = await poolService.activePool(paneID: snapshot.paneID, bufferBeforeCursor: bufferBeforeCursor) {
                hadSuggestionContext = true
                consumptionSource = "pool"
                FIMTraceLogger.shared.log("pool.active", [
                    "anchor": String(pool.anchorPrefix.suffix(20)).replacingOccurrences(of: "\n", with: "\\n"),
                    "variants": "\(pool.variants.count)"
                ])
                candidates = pool.variants
            } else if let lastShown = session.lastShownSuggestion,
                      !lastShown.isEmpty,
                      let shownCursor = session.lastShownCursor,
                      !bufferBeforeCursor.dropFirst(shownCursor).contains("\n") {
                hadSuggestionContext = true
                candidates = [InlineCompletionVariant(
                    id: UUID(), text: lastShown, temperature: 0.1,
                    bannedTokenCount: 0, createdAt: Date()
                )]
            }

            if let consumption = SuggestionConsumptionPolicy.consume(
                from: candidates, bufferBeforeCursor: bufferBeforeCursor
            ) {
                if let remainder = consumption.remainder {
                    self.publish(InlineSuggestionPresentation(
                        requestId: UUID(), suggestionText: remainder,
                        source: .local, confidenceScore: 0.5, latencyMs: 0
                    ), for: snapshot.paneID)
                } else {
                    self.publish(nil, for: snapshot.paneID)
                }
                FIMTraceLogger.shared.log("consume.\(consumptionSource)", ["head": "matched"])
                return
            }
            if hadSuggestionContext {
                FIMTraceLogger.shared.log("consume.\(consumptionSource)", ["head": "miss-deviation"])
            }

            let rejectCount = self.recentRejections[snapshot.paneID] ?? 0
            guard self.gate.shouldRequest(
                for: snapshot,
                gapMs: gapMs, typedChar: typedChar, recentRejectionCount: rejectCount
            ) else {
                FIMTraceLogger.shared.log("gate", ["decision": "reject", "gapMs": String(format: "%.0f", gapMs)])
                self.publish(nil, for: snapshot.paneID)
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

            FIMTraceLogger.shared.log("infer.start", [
                "prefixLen": "\(context.prefix.count)",
                "suffixLen": "\(context.suffix.count)",
                "maxTokens": "\(request.maxTokens)",
                "gapMs": String(format: "%.0f", gapMs)
            ])

            do {
                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.generating)

                guard let stream = try await self.inferenceService.inferStreaming(for: request, settings: settings) else {
                    self.publish(nil, for: snapshot.paneID)
                    NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.noSuggestion)
                    return
                }

                // Ghost publishes are rate-limited: first chunk instantly,
                // then at most every 100ms, final on completion.
                var throttle = GhostPublishThrottle()
                var publishedPartial: InlineSuggestionPresentation?
                var accumulated = ""
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
                        publishedPartial = candidate
                        if throttle.shouldPublish() {
                            throttle.didPublish()
                            self.publish(candidate, for: snapshot.paneID)
                        }
                    }
                }
                let result: InlineCompletionResult? = accumulated.isEmpty ? nil : InlineCompletionResult(
                    requestId: requestID, suggestionText: accumulated,
                    confidenceScore: 0.5, source: .local, latencyMs: 0
                )

                guard let result else {
                    self.publish(nil, for: snapshot.paneID)
                    NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.noSuggestion)
                    return
                }

                guard !Task.isCancelled else { return }
                guard self.activeRequestIDs[snapshot.paneID] == requestID else { return }

                let evaluation = self.ranker.evaluate(result, for: request, aggressiveness: settings.aggressiveness)
                switch evaluation {
                case .accepted(let candidate):
                    if let lastAccepted = self.lastAcceptedSuggestions[snapshot.paneID],
                       candidate.suggestionText == lastAccepted {
                        self.publish(nil, for: snapshot.paneID)
                    } else {
                        self.recentRejections[snapshot.paneID] = 0
                        // Republish only when the final differs from the last
                        // shown partial (avoids a redundant ghost refresh).
                        if candidate.suggestionText != publishedPartial?.suggestionText {
                            self.publish(candidate, for: snapshot.paneID)
                        }
                    }
                case .rejected:
                    self.recentRejections[snapshot.paneID] = (self.recentRejections[snapshot.paneID] ?? 0) + 1
                    // Keep the last partial ghost — never yank a shown
                    // suggestion on a final ranker rejection.
                    if publishedPartial == nil {
                        self.publish(nil, for: snapshot.paneID)
                    }
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
                    FIMTraceLogger.shared.log("deviation.seed", [
                        "text": String(result.suggestionText.prefix(40)),
                        "firstToken": "\(firstToken ?? -1)"
                    ])
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
                FIMTraceLogger.shared.log("infer.result", [
                    "outputLen": "\(result.suggestionText.count)",
                    "accepted": "\(evaluation.isAccepted ? "yes" : "no")"
                ])

                NotificationCenter.default.post(name: .inlineCompletionStatusDidChange, object: InlineCompletionStatus.idle)
            } catch {
                self.publish(nil, for: snapshot.paneID)
            }
        }
    }

    /// The chain appended variants — re-publish the pool's new top suggestion
    /// if it changed (throttled to avoid ghost flicker), then notify the
    /// coordinator (event-driven dropdown refresh).
    nonisolated private func poolVariantsChanged(paneID: PaneID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            let session = self.session(for: paneID)
            if let last = session.lastPoolPublishAt,
               now.timeIntervalSince(last) * 1000 < 150 {
                self.onPoolVariantsChanged?(paneID)
                return
            }
            guard let poolService = self.variantPoolService,
                  let buffer = session.lastBufferBeforeCursor,
                  let pool = await poolService.activePool(paneID: paneID, bufferBeforeCursor: buffer),
                  let top = pool.variants.first else {
                self.onPoolVariantsChanged?(paneID)
                return
            }
            self.updateSession(paneID) { $0.lastPoolPublishAt = now }
            if top.text != session.lastShownSuggestion {
                self.publish(InlineSuggestionPresentation(
                    requestId: UUID(), suggestionText: top.text,
                    source: .local, confidenceScore: 0.5, latencyMs: 0
                ), for: paneID)
            }
            self.onPoolVariantsChanged?(paneID)
        }
    }

    func invalidate(_ paneID: PaneID) {
        requestTasks[paneID]?.cancel()
        requestTasks[paneID] = nil
        activeRequestIDs.removeValue(forKey: paneID)
        sessions.removeValue(forKey: paneID)
        if let poolService = variantPoolService {
            Task { await poolService.reset(paneID: paneID) }
        }
        publish(nil, for: paneID)
    }

    func markAccepted(on paneID: PaneID, suggestionText: String?) {
        if let suggestionText, !suggestionText.isEmpty {
            lastAcceptedSuggestions[paneID] = suggestionText
            lastAcceptedAt[paneID] = Date()
            let cursor = session(for: paneID).lastBufferBeforeCursor?.count ?? 0
            updateSession(paneID) {
                $0.lastShownSuggestion = suggestionText
                $0.lastShownCursor = cursor
            }
        }
    }

    func markDismissed(on paneID: PaneID) {
        updateSession(paneID) {
            $0.lastShownSuggestion = nil
            $0.lastShownCursor = nil
        }
    }

    // MARK: - Session state

    private func session(for paneID: PaneID) -> CompletionSessionState {
        sessions[paneID] ?? CompletionSessionState()
    }

    private func updateSession(_ paneID: PaneID, _ mutate: (inout CompletionSessionState) -> Void) {
        var state = sessions[paneID] ?? CompletionSessionState()
        mutate(&state)
        sessions[paneID] = state
    }

    private func publish(_ presentation: InlineSuggestionPresentation?, for paneID: PaneID) {
        if let presentation {
            let cursor = session(for: paneID).lastBufferBeforeCursor?.count ?? 0
            updateSession(paneID) {
                $0.lastShownSuggestion = presentation.suggestionText
                $0.lastShownCursor = cursor
            }
        }
        suggestionHandlers[paneID]?(presentation)
    }
}
