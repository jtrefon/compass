import Foundation

/// A single alternative completion (FIM_VariantPools_Arch.md §4).
struct InlineCompletionVariant: Sendable, Equatable {
    let id: UUID
    /// Single-line suggestion text (renderer clamps at the first newline anyway).
    let text: String
    let temperature: Float
    let bannedTokenCount: Int
    let createdAt: Date
    var rankScore: Double
}

/// A pool of variants generated for one branch point of the typing path.
/// Anchored by the buffer tail at creation; served while the user's buffer
/// still extends that anchor (longest-anchor match wins).
struct VariantPool: Sendable {
    let id: UUID
    let paneID: FileEditorStateManager.PaneID
    let anchorPrefix: String
    let anchorCursor: Int
    var variants: [InlineCompletionVariant]
    var lastHitAt: Date
    var byteSize: Int
}

/// Session-lifetime pool storage with LRU eviction under a byte budget
/// (FIM_VariantPools_Arch.md §3). Pools live until the app closes — the
/// budget cap is only a safety floor (8 pools × 5 variants × ~200 chars ≈
/// 8KB, far below the default 256KB).
actor VariantPoolStore {
    private var poolsByPane: [FileEditorStateManager.PaneID: [VariantPool]] = [:]
    private let byteBudget: Int

    init(byteBudget: Int = 256 * 1024) {
        self.byteBudget = byteBudget
    }

    func reset(paneID: FileEditorStateManager.PaneID) {
        poolsByPane.removeValue(forKey: paneID)
    }

    func resetAll() {
        poolsByPane.removeAll()
    }

    func upsert(_ pool: VariantPool) {
        var pools = poolsByPane[pool.paneID] ?? []
        pools.removeAll { $0.id == pool.id }
        pools.append(pool)
        poolsByPane[pool.paneID] = pools
        evictIfNeeded()
    }

    /// The most specific pool whose anchor the typing path still passes
    /// through: the buffer region before the branch cursor must be unchanged
    /// (it ends with the anchor). Backspace past the branch makes the newer
    /// pool unmatchable and an older pool takes over.
    func activePool(
        paneID: FileEditorStateManager.PaneID,
        bufferBeforeCursor: String
    ) -> VariantPool? {
        guard let pools = poolsByPane[paneID] else { return nil }
        var best: VariantPool?
        for var pool in pools {
            guard bufferBeforeCursor.count >= pool.anchorCursor else { continue }
            let branchRegion = bufferBeforeCursor.prefix(pool.anchorCursor)
            guard branchRegion.hasSuffix(pool.anchorPrefix) else { continue }
            if best == nil || pool.anchorPrefix.count > best!.anchorPrefix.count {
                pool.lastHitAt = Date()
                best = pool
            }
        }
        if let best {
            poolsByPane[paneID] = pools.map { $0.id == best.id ? best : $0 }
        }
        return best
    }

    /// All variants for a pane, ranked best-first across pools (newest pool
    /// first, then rank order within the pool).
    func variants(paneID: FileEditorStateManager.PaneID) -> [InlineCompletionVariant] {
        guard let pools = poolsByPane[paneID] else { return [] }
        return pools
            .sorted { $0.lastHitAt > $1.lastHitAt }
            .flatMap { $0.variants.sorted { $0.rankScore > $1.rankScore } }
    }

    func appendVariant(
        paneID: FileEditorStateManager.PaneID,
        poolID: UUID,
        variant: InlineCompletionVariant
    ) {
        guard var pools = poolsByPane[paneID] else { return }
        guard let idx = pools.firstIndex(where: { $0.id == poolID }) else { return }
        pools[idx].variants.append(variant)
        pools[idx].lastHitAt = Date()
        pools[idx].byteSize += variant.text.utf8.count + 64
        poolsByPane[paneID] = pools
        evictIfNeeded()
    }

    /// Rejection demotion: move the pool's top variant to the back so the
    /// second-best becomes the auto-suggestion.
    func demoteTop(paneID: FileEditorStateManager.PaneID, poolID: UUID) {
        guard var pools = poolsByPane[paneID] else { return }
        guard let idx = pools.firstIndex(where: { $0.id == poolID }) else { return }
        guard pools[idx].variants.count > 1 else { return }
        let top = pools[idx].variants.removeFirst()
        pools[idx].variants.append(top)
        poolsByPane[paneID] = pools
    }

    func poolByteSize() -> Int {
        poolsByPane.values.flatMap { $0 }.reduce(0) { $0 + $1.byteSize }
    }

    /// Number of variants in a specific pool (chain stop condition).
    func variantCount(paneID: FileEditorStateManager.PaneID, poolID: UUID) -> Int {
        guard let pools = poolsByPane[paneID] else { return 0 }
        return pools.first { $0.id == poolID }?.variants.count ?? 0
    }

    /// The most recently hit pool for a pane (rejection-demotion target).
    func mostRecentPool(paneID: FileEditorStateManager.PaneID) -> VariantPool? {
        poolsByPane[paneID]?.max { $0.lastHitAt < $1.lastHitAt }
    }

    private func evictIfNeeded() {
        var total = poolByteSize()
        guard total > byteBudget else { return }
        // Evict least-recently-hit pools across all panes until under budget.
        var allPools: [(paneID: FileEditorStateManager.PaneID, pool: VariantPool)] = []
        for (paneID, pools) in poolsByPane {
            for pool in pools {
                allPools.append((paneID, pool))
            }
        }
        allPools.sort { $0.pool.lastHitAt < $1.pool.lastHitAt }
        for entry in allPools where total > byteBudget {
            poolsByPane[entry.paneID]?.removeAll { $0.id == entry.pool.id }
            total -= entry.pool.byteSize
        }
    }
}
