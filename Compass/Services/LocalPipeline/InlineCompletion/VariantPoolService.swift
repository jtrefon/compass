import Foundation

/// Background variant chaining (FIM_VariantPools_Arch.md §4-5).
///
/// On a deviation, a pool is anchored at the current buffer tail and a
/// detached chain fills it with up to 5 variants: the standard prediction
/// (temp 0.1, no ban) followed by hard-banned first tokens + a temperature
/// ladder. All variants share the prompt — the warm KV cache makes each
/// additional variant ~150ms (measured).
///
/// The chain runs fully off the main actor; it only hops through the provider
/// (which owns the single shared FIM container). A new deviation bumps the
/// pane's chain revision and cancels the running chain.
actor VariantPoolService {
    static let variantTemps: [Float] = [0.3, 0.5, 0.5, 0.7]
    static let maxVariantsPerPool = 5
    /// Skip a variant when it is this similar to an existing one.
    static let dedupSimilarityThreshold = 0.9
    static let anchorLength = 80

    private let store: VariantPoolStore
    private let provider: any InlineCompletionProviding
    private var chainTasks: [FileEditorStateManager.PaneID: Task<Void, Never>] = [:]
    private var chainRevisions: [FileEditorStateManager.PaneID: Int] = [:]

    /// Fired (off-main) after a variant is appended — the engine re-publishes
    /// the pool's new top suggestion (throttled). Set once at construction,
    /// before any chain runs.
    nonisolated(unsafe) var onVariantsChanged: (@Sendable (FileEditorStateManager.PaneID) -> Void)?

    init(
        store: VariantPoolStore = VariantPoolStore(),
        provider: any InlineCompletionProviding
    ) {
        self.store = store
        self.provider = provider
    }

    /// Called by the engine when the typed char does not extend any variant
    /// head: anchors a new pool and starts (or restarts) the chain.
    /// `seededVariantText`/`seededFirstTokenID` carry the engine's standard
    /// prediction for this context (it becomes pool[0] without re-generating).
    func registerDeviation(
        paneID: FileEditorStateManager.PaneID,
        bufferBeforeCursor: String,
        cursor: Int,
        prefix: String,
        suffix: String,
        maxTokens: Int,
        seededVariantText: String? = nil,
        seededFirstTokenID: Int? = nil
    ) {
        chainRevisions[paneID, default: 0] += 1
        let revision = chainRevisions[paneID]!
        chainTasks[paneID]?.cancel()

        let anchor = String(bufferBeforeCursor.suffix(Self.anchorLength))
        let pool = VariantPool(
            id: UUID(),
            paneID: paneID,
            anchorPrefix: anchor,
            anchorCursor: cursor,
            variants: [],
            lastHitAt: Date(),
            byteSize: 0
        )
        Task { await store.upsert(pool) }

        chainTasks[paneID] = Task { [weak self] in
            FIMTraceLogger.shared.log("chain.start", [
                "pane": "\(paneID)",
                "seeded": seededVariantText.map { "\($0.prefix(30))" } ?? "no",
                "anchor": String(anchor.prefix(20)).replacingOccurrences(of: "\n", with: "\\n")
            ])
            await self?.runChain(
                paneID: paneID,
                poolID: pool.id,
                revision: revision,
                prefix: prefix,
                suffix: suffix,
                maxTokens: maxTokens,
                seededVariantText: seededVariantText,
                seededFirstTokenID: seededFirstTokenID
            )
        }
    }

    /// The active pool for the current buffer (longest-anchor match), if any.
    func activePool(paneID: FileEditorStateManager.PaneID, bufferBeforeCursor: String) async -> VariantPool? {
        await store.activePool(paneID: paneID, bufferBeforeCursor: bufferBeforeCursor)
    }

    /// All variants for a pane, best-first.
    func variants(paneID: FileEditorStateManager.PaneID) async -> [InlineCompletionVariant] {
        await store.variants(paneID: paneID)
    }

    /// Rejection demotion: the user keeps typing over the top variant —
    /// promote the second-best as the auto-suggestion.
    func demoteTop(paneID: FileEditorStateManager.PaneID) async {
        guard let pool = await store.mostRecentPool(paneID: paneID) else { return }
        await store.demoteTop(paneID: paneID, poolID: pool.id)
    }

    func reset(paneID: FileEditorStateManager.PaneID) {
        chainTasks[paneID]?.cancel()
        chainTasks.removeValue(forKey: paneID)
        chainRevisions.removeValue(forKey: paneID)
        Task { await store.reset(paneID: paneID) }
    }

    // MARK: - Chain

    private func runChain(
        paneID: FileEditorStateManager.PaneID,
        poolID: UUID,
        revision: Int,
        prefix: String,
        suffix: String,
        maxTokens: Int,
        seededVariantText: String?,
        seededFirstTokenID: Int?
    ) async {
        var bans: [Int] = []
        if let seededVariantText, !seededVariantText.isEmpty {
            // The engine's standard prediction seeds pool[0] — no regeneration.
            await store.appendVariant(
                paneID: paneID,
                poolID: poolID,
                variant: InlineCompletionVariant(
                    id: UUID(),
                    text: seededVariantText,
                    temperature: 0.1,
                    bannedTokenCount: 0,
                    createdAt: Date(),
                    rankScore: 0.5
                )
            )
            onVariantsChanged?(paneID)
            if let seededFirstTokenID {
                bans.append(seededFirstTokenID)
            }
        } else {
            // Variant 1: the standard prediction (no ban, production temp).
            if let firstID = await generateVariant(
                paneID: paneID, poolID: poolID, revision: revision,
                prefix: prefix, suffix: suffix, maxTokens: maxTokens,
                temperature: 0.1, bans: []
            ) {
                bans.append(firstID)
            }
        }
        for temp in Self.variantTemps {
            guard !Task.isCancelled, revision == chainRevisions[paneID] else { return }
            guard await store.variantCount(paneID: paneID, poolID: poolID) < Self.maxVariantsPerPool else { return }
            if let firstID = await generateVariant(
                paneID: paneID, poolID: poolID, revision: revision,
                prefix: prefix, suffix: suffix, maxTokens: maxTokens,
                temperature: temp, bans: bans
            ) {
                if !bans.contains(firstID) {
                    bans.append(firstID)
                }
            }
        }
    }

    private func generateVariant(
        paneID: FileEditorStateManager.PaneID,
        poolID: UUID,
        revision: Int,
        prefix: String,
        suffix: String,
        maxTokens: Int,
        temperature: Float,
        bans: [Int]
    ) async -> Int? {
        do {
            guard let stream = try await provider.completeLocallyStreaming(
                prefix: prefix,
                suffix: suffix,
                maxTokens: maxTokens,
                bannedTokenIDs: bans,
                variantTemperature: temperature
            ) else { return nil }

            var text = ""
            for try await chunk in stream {
                if Task.isCancelled || revision != chainRevisions[paneID] { return nil }
                text.append(chunk)
            }
            // Variants are single-line; clamp at the first newline.
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[..<newline])
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }

            // Dedup against the pool's existing variants.
            let existing = await store.variants(paneID: paneID)
            if existing.contains(where: { similarity($0.text, text) >= Self.dedupSimilarityThreshold }) {
                return nil
            }

            let firstID = await provider.lastGeneratedFirstTokenID()
            await store.appendVariant(
                paneID: paneID,
                poolID: poolID,
                variant: InlineCompletionVariant(
                    id: UUID(),
                    text: text,
                    temperature: temperature,
                    bannedTokenCount: bans.count,
                    createdAt: Date(),
                    rankScore: 0.5
                )
            )
            FIMTraceLogger.shared.log("chain.variant", [
                "pane": "\(paneID)",
                "temp": String(format: "%.1f", temperature),
                "bans": "\(bans.count)",
                "firstToken": "\(firstID ?? -1)",
                "text": String(text.prefix(30))
            ])
            onVariantsChanged?(paneID)
            return firstID
        } catch {
            return nil
        }
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 1.0 - Double(levenshtein(a, b)) / Double(max(a.count, b.count))
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for (i, ca) in aChars.enumerated() {
            curr[0] = i + 1
            for (j, cb) in bChars.enumerated() {
                curr[j + 1] = ca == cb ? prev[j] : min(prev[j], prev[j + 1], curr[j]) + 1
            }
            (prev, curr) = (curr, prev)
        }
        return prev[bChars.count]
    }
}
