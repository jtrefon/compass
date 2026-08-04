import Foundation
import Combine

@MainActor
final class IndexStatusBarViewModel: ObservableObject {
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var processedCount: Int = 0
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var currentFile: URL?
    @Published private(set) var stats: IndexStats?


    @Published private(set) var vectorStoreEntryCount: Int = 0
    @Published private(set) var vectorStoreIsLoaded: Bool = false
    @Published private(set) var vectorStoreError: Bool = false
    @Published private(set) var isIngesting: Bool = false
    @Published private(set) var ingestionProgress: Int = 0
    @Published private(set) var ingestionTotal: Int = 0

    @Published private(set) var openRouterContextUsageText: String = ""
    @Published private(set) var localModelContextUsageText: String = ""
    @Published private(set) var remoteAICostText: String = ""
    @Published private(set) var remoteAISpendText: String = ""
    @Published private(set) var remoteAIBalanceText: String = ""
    @Published private(set) var generationSpeedText: String = ""

    @Published private(set) var isDownloadingFIM: Bool = false
    @Published private(set) var fimDownloadFraction: Double = 0
    @Published private(set) var isFIMAvailable: Bool = false
    @Published private(set) var fimCompletionStatus: InlineCompletionStatus = .idle

    private let codebaseIndexProvider: () -> CodebaseIndexProtocol?
    private let vectorStoreProvider: () -> VectorStoreService?
    private let eventBus: EventBusProtocol
    private let refreshRemoteAIAccountBalance: @Sendable (_ runId: String?) async -> Void
    private let statsPollInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: AnyCancellable?
    private var accumulatedRemoteCostMicrodollars: Int = 0
    /// Real cumulative prompt tokens from completed API responses
    private var accumulatedPromptTokens: Int = 0
    /// Streaming estimate for the current in-flight response
    private var streamingPromptEstimate: Int = 0
    private let tokenRateTracker = TokenRateTracker()

    init(
        codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?,
        vectorStoreProvider: @escaping () -> VectorStoreService? = { nil },
        eventBus: EventBusProtocol,
        refreshRemoteAIAccountBalance: @escaping @Sendable (_ runId: String?) async -> Void = { _ in },
        statsPollInterval: TimeInterval = 30.0
    ) {
        self.codebaseIndexProvider = codebaseIndexProvider
        self.vectorStoreProvider = vectorStoreProvider
        self.eventBus = eventBus
        self.refreshRemoteAIAccountBalance = refreshRemoteAIAccountBalance
        self.statsPollInterval = max(0.1, statsPollInterval)

        subscribeToEvents()
        startStatsPolling()
        refreshStats()
        scheduleInitialRemoteBalanceRefresh()
        refreshFIMAvailability()
    }

    var statusText: String {
        if isDownloadingFIM {
            return "Downloading completions model \(Int(fimDownloadFraction * 100))%"
        }

        // RAG retrieval has highest priority

        if isIndexing {
            if totalCount > 0 {
                let fileName = currentFile?.lastPathComponent
                if let fileName, !fileName.isEmpty {
                    return "Indexing \(processedCount)/\(totalCount): \(fileName)"
                }
                return "Indexing \(processedCount)/\(totalCount)"
            }
            return "Indexing…"
        }

        if let stats {
            let vsInfo: String
            if vectorStoreError {
                vsInfo = "VS Err"
            } else if isIngesting {
                vsInfo = "VS embedding \(ingestionProgress)/\(ingestionTotal)"
            } else if vectorStoreIsLoaded {
                vsInfo = "VS OK"
            } else {
                vsInfo = "VS init"
            }
            let acInfo = acStatusText
            if stats.totalProjectFileCount > 0 {
                let indexed = min(stats.indexedResourceCount, stats.totalProjectFileCount)
                return "IDX \(indexed)/\(stats.totalProjectFileCount) | \(vsInfo) | \(acInfo)"
            }
            return "IDX \(stats.indexedResourceCount) | \(vsInfo) | \(acInfo)"
        }

        return "Index: unavailable"
    }

    var acStatusText: String {
        guard isFIMAvailable else { return "AC -" }
        switch fimCompletionStatus {
        case .generating: return "AC WIP"
        case .idle, .noSuggestion: return "AC OK"
        }
    }

    var metricsText: String {
        guard let stats else {
            return ""
        }

        let vsCount = vectorStoreError ? "ERR" : (vectorStoreIsLoaded ? "\(vectorStoreEntryCount)" : "-")
        let size = formatBytes(stats.databaseSizeBytes)
        let score = stats.aiEnrichedResourceCount > 0 && stats.averageAIQualityScore > 0
            ? stats.averageAIQualityScore
            : stats.averageQualityScore
        let quality = score > 0 ? String(format: "%.0f", score) : "0"
        return "VS \(vsCount) | C \(stats.classCount) | F \(stats.functionCount) | S \(stats.symbolCount) | Q \(quality) | IDX \(size)"
    }

    // MARK: - Icon-first status bar data (additive; legacy *Text props kept for tests)

    /// "132/148" — indexed files over total project files (empty when no stats).
    var indexFilesText: String {
        guard let stats else { return "" }
        if stats.totalProjectFileCount > 0 {
            let indexed = min(stats.indexedResourceCount, stats.totalProjectFileCount)
            return "\(indexed)/\(stats.totalProjectFileCount)"
        }
        return "\(stats.indexedResourceCount)"
    }

    /// Vector-store summary for the icon strip: entry count, or state text.
    var vectorStoreCountText: String {
        if vectorStoreError { return "ERR" }
        if isIngesting { return "\(ingestionProgress)/\(ingestionTotal)" }
        return vectorStoreIsLoaded ? "\(vectorStoreEntryCount)" : "–"
    }

    /// Auto-complete state label for the icon strip (short).
    var acShortText: String {
        guard isFIMAvailable else { return "–" }
        switch fimCompletionStatus {
        case .generating: return "WIP"
        case .idle, .noSuggestion: return "OK"
        }
    }

    /// Structured symbol analytics for the diagnostics popover.
    var symbolBreakdown: IndexSymbolBreakdown? {
        guard let stats else { return nil }
        return IndexSymbolBreakdown(
            indexedFiles: stats.indexedResourceCount,
            totalFiles: stats.totalProjectFileCount,
            classCount: stats.classCount,
            functionCount: stats.functionCount,
            structCount: stats.structCount,
            enumCount: stats.enumCount,
            protocolCount: stats.protocolCount,
            variableCount: stats.variableCount,
            symbolCount: stats.symbolCount,
            qualityScore: stats.aiEnrichedResourceCount > 0 && stats.averageAIQualityScore > 0
                ? stats.averageAIQualityScore
                : stats.averageQualityScore,
            databaseSizeBytes: stats.databaseSizeBytes,
            vectorStoreEntryCount: vectorStoreError ? -1 : vectorStoreEntryCount,
            vectorStoreIsLoaded: vectorStoreIsLoaded,
            vectorStoreError: vectorStoreError,
            isIngesting: isIngesting,
            ingestionProgress: ingestionProgress,
            ingestionTotal: ingestionTotal
        )
    }

    private func subscribeToEvents() {
        eventBus.subscribe(to: IndexingStartedEvent.self) { [weak self] _ in
            guard let self else { return }
            self.isIndexing = true
            self.processedCount = 0
            self.totalCount = max(self.totalCount, 0)
            self.currentFile = nil
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: IndexingProgressEvent.self) { [weak self] event in
            guard let self else { return }
            self.isIndexing = true
            self.processedCount = event.processedCount
            self.totalCount = event.totalCount
            self.currentFile = event.currentFile
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: IndexingCompletedEvent.self) { [weak self] _ in
            guard let self else { return }
            self.isIndexing = false
            self.currentFile = nil
            self.refreshStats()
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: VectorStoreStatusChangedEvent.self) { [weak self] event in
            guard let self else { return }
            self.vectorStoreEntryCount = event.entryCount
            self.vectorStoreIsLoaded = event.isLoaded
            self.vectorStoreError = event.isError
            self.isIngesting = false
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: VectorStoreIngestionProgressEvent.self) { [weak self] event in
            guard let self else { return }
            self.isIngesting = true
            self.ingestionProgress = event.ingestedCount
            self.ingestionTotal = event.totalCount
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: StreamingContextUsageEvent.self) { [weak self] event in
            guard let self else { return }
            if event.isFinal {
                // Run finished: if the authoritative usage event never arrived
                // (e.g. local model), the final estimate IS the run's total.
                if !self.usageSeenForCurrentRun {
                    self.accumulatedPromptTokens = event.estimatedPromptTokens
                }
                self.streamingPromptEstimate = 0
            } else {
                // New run starts: reset the per-run totals. The previous
                // implementation accumulated every run into a session total
                // that capped at the window — showing 262K/262K forever.
                if event.runId != self.lastUsageRunId {
                    self.lastUsageRunId = event.runId
                    self.usageSeenForCurrentRun = false
                    self.accumulatedPromptTokens = 0
                    self.accumulatedCompletionTokens = 0
                }
                // Smoothly update the display during streaming
                self.streamingPromptEstimate = event.estimatedPromptTokens
            }
            self.updateContextDisplay()
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: OpenRouterUsageUpdatedEvent.self) { [weak self] event in
            guard let self else { return }
            // Real token count from the API response — the authoritative
            // per-run numbers (assignment, not accumulation).
            self.accumulatedPromptTokens = event.usage.promptTokens
            self.accumulatedCompletionTokens = event.usage.completionTokens
            self.usageSeenForCurrentRun = true
            self.streamingPromptEstimate = 0
            if let contextLength = event.contextLength, contextLength > 0 {
                self.observedContextWindowTokens = contextLength
            }
            self.updateContextDisplay()
            self.remoteAICostText = self.formatRemoteCost(
                providerName: event.providerName,
                costMicrodollars: event.usage.costMicrodollars
            )
            if let costMicrodollars = event.usage.costMicrodollars, costMicrodollars > 0 {
                self.accumulatedRemoteCostMicrodollars += costMicrodollars
            }
            self.remoteAISpendText = self.formatObservedSpend(
                providerName: event.providerName,
                accumulatedCostMicrodollars: self.accumulatedRemoteCostMicrodollars
            )
            self.remoteAIBalanceText = self.formatAccountBalance(
                providerName: event.providerName,
                accountBalanceMicrodollars: event.usage.accountBalanceMicrodollars
            )
            self.tokenRateTracker.record(promptTokens: event.usage.promptTokens, completionTokens: event.usage.completionTokens)
            self.generationSpeedText = self.tokenRateTracker.speedText
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: ConversationContextEvent.self) { [weak self] event in
            guard let self else { return }
            // Convert chars to estimated tokens (4 chars ≈ 1 token) for consistency
            // with the remote display which reports actual token counts.
            let estTokens = max(1, event.totalCharCount / 4)
            if let windowChars = event.contextWindowChars {
                let windowTokens = max(1, windowChars / 4)
                let used = min(estTokens, windowTokens)
                self.localModelContextUsageText = "CTX \(Self.formatTokenCount(used))/\(Self.formatTokenCount(windowTokens))"
            } else {
                self.localModelContextUsageText = "CTX ~\(Self.formatTokenCount(estTokens)) · \(event.messageCount) msgs"
            }
            if let ratio = event.compressionRatio {
                self.localModelContextUsageText += " · \(String(format: "%.1fx", ratio))"
            }
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: RemoteAIAccountBalanceUpdatedEvent.self) { [weak self] event in
            guard let self else { return }
            self.remoteAIBalanceText = self.formatAccountBalance(
                providerName: event.providerName,
                accountBalanceMicrodollars: event.accountBalanceMicrodollars
            )
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: ConversationRunCompletedEvent.self) { [weak self] event in
            guard let self else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.refreshRemoteAIAccountBalance(event.runId)
            }
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: ModelDownloadProgressEvent.self) { [weak self] event in
            guard let self else { return }
            self.isDownloadingFIM = true
            self.fimDownloadFraction = event.fractionCompleted
        }
        .store(in: &cancellables)

        eventBus.subscribe(to: ModelDownloadCompletedEvent.self) { [weak self] _ in
            guard let self else { return }
            self.isDownloadingFIM = false
            self.fimDownloadFraction = 0
            self.isFIMAvailable = true
        }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .inlineCompletionStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let status = note.object as? InlineCompletionStatus else { return }
            Task { @MainActor [self] in
                self?.fimCompletionStatus = status
            }
        }
    }

    private func refreshFIMAvailability() {
        let model = LocalModelCatalog.fimModel
        isFIMAvailable = LocalModelFileStore.isModelInstalled(model)
    }

    private func scheduleInitialRemoteBalanceRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshRemoteAIAccountBalance(nil)
        }
    }

    private func startStatsPolling() {
        statsTimer = Timer
            .publish(every: statsPollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStats()
                self?.refreshVectorStoreState()
            }
    }

    private func refreshVectorStoreState() {
        if vectorStoreError { return }
        guard !vectorStoreIsLoaded, let vs = vectorStoreProvider() else {
            if !vectorStoreIsLoaded {
            }
            return
        }
        Task { @MainActor in
            let count = await vs.entryCount
            self.vectorStoreEntryCount = count
            self.vectorStoreIsLoaded = true
        }
    }

    private func refreshStats() {
        guard let codebaseIndex = codebaseIndexProvider() else { return }
        Task { @MainActor in
            self.stats = try? await codebaseIndex.getStats()
        }
    }

    private static func formatCharCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let k = Double(count) / 1000.0
        if k < 1000 { return String(format: "%.1fK", k) }
        return String(format: "%.1fM", k / 1000.0)
    }

    /// Update the context display with the current accumulated + streaming estimate
    private func updateContextDisplay() {
        let total = accumulatedPromptTokens + accumulatedCompletionTokens + streamingPromptEstimate
        let ceOverride = CustomEndpointSettingsStore().load(includeApiKey: false).contextOverride
        let windowTokens = observedContextWindowTokens > 0
            ? observedContextWindowTokens
            : (ceOverride > 0 ? ceOverride : 262_000)
        let used = min(total, windowTokens)
        openRouterContextUsageText = "CTX \(Self.formatTokenCount(used))/\(Self.formatTokenCount(windowTokens))"
    }

    /// Completion tokens reported by the provider (displayed alongside prompt tokens).
    private var accumulatedCompletionTokens = 0
    /// runId of the run currently shown — a new run resets the totals.
    private var lastUsageRunId: String?
    /// Whether the authoritative usage event arrived for the current run.
    private var usageSeenForCurrentRun = false
    /// Context window (tokens) reported by the provider in the last usage event.
    private var observedContextWindowTokens = 0

    private static func formatTokenCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let k = Double(count) / 1000.0
        if k < 10 { return String(format: "%.1fK", k) }
        return String(format: "%.0fK", k)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let absBytes = Double(bytes)
        if absBytes < 1024 { return "\(bytes) B" }
        let kb = absBytes / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    private func formatRemoteCost(providerName: String, costMicrodollars: Int?) -> String {
        guard let costMicrodollars else { return "" }
        if providerName == "Kilo Code" {
            return ""
        }
        return "\(providerName) \(CostDisplayFormatter.dollarAmount(fromMicrodollars: costMicrodollars))"
    }

    private func formatObservedSpend(providerName: String, accumulatedCostMicrodollars: Int) -> String {
        guard accumulatedCostMicrodollars > 0 else { return "" }
        return "\(providerName) spent \(CostDisplayFormatter.dollarAmount(fromMicrodollars: accumulatedCostMicrodollars))"
    }

    private func formatAccountBalance(
        providerName: String,
        accountBalanceMicrodollars: Int?
    ) -> String {
        guard let accountBalanceMicrodollars, accountBalanceMicrodollars >= 0 else { return "" }
        return "\(providerName) balance \(CostDisplayFormatter.dollarAmount(fromMicrodollars: accountBalanceMicrodollars))"
    }
}

/// Structured symbol analytics for the status-bar diagnostics popover.
struct IndexSymbolBreakdown: Sendable {
    let indexedFiles: Int
    let totalFiles: Int
    let classCount: Int
    let functionCount: Int
    let structCount: Int
    let enumCount: Int
    let protocolCount: Int
    let variableCount: Int
    let symbolCount: Int
    let qualityScore: Double
    let databaseSizeBytes: Int64
    let vectorStoreEntryCount: Int
    let vectorStoreIsLoaded: Bool
    let vectorStoreError: Bool
    let isIngesting: Bool
    let ingestionProgress: Int
    let ingestionTotal: Int
}

/// Tracks tokens-per-second for generation. Smoothed over a 3-event window
/// to avoid jitter from individual chunk updates.
@MainActor
final class TokenRateTracker {
    private struct Sample {
        let timestamp: Date
        let tokenCount: Int
    }

    private var samples: [Sample] = []
    private let maxSamples = 10

    func record(promptTokens: Int, completionTokens: Int) {
        samples.append(Sample(timestamp: Date(), tokenCount: completionTokens))
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }

    var tokensPerSecond: Double {
        guard samples.count >= 2 else { return 0 }
        let first = samples.first!
        let last = samples.last!
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        guard elapsed > 0 else { return 0 }
        let totalTokens = last.tokenCount - first.tokenCount
        guard totalTokens > 0 else { return 0 }
        return Double(totalTokens) / elapsed
    }

    var speedText: String {
        let tps = tokensPerSecond
        guard tps > 0 else { return "" }
        if tps >= 10 {
            return "\(Int(tps)) t/s"
        }
        return String(format: "%.1f t/s", tps)
    }
}
