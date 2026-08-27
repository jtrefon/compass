import SwiftUI

struct IndexStatusBarView: View {
    @ObservedObject private var appState: AppState
    @StateObject private var viewModel: IndexStatusBarViewModel
    @AppStorage(AppConstantsStorage.statusBarVerboseMetricsKey, store: AppRuntimeEnvironment.userDefaults)
    private var verboseMetrics: Bool = false

    init(
        appState: AppState,
        codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?,
        vectorStoreProvider: @escaping () -> VectorStoreService?,
        eventBus: EventBusProtocol,
        refreshRemoteAIAccountBalance: @escaping @Sendable (_ runId: String?) async -> Void
    ) {
        self.appState = appState
        self._viewModel = StateObject(
            wrappedValue: IndexStatusBarViewModel(
                codebaseIndexProvider: codebaseIndexProvider,
                vectorStoreProvider: vectorStoreProvider,
                eventBus: eventBus,
                refreshRemoteAIAccountBalance: refreshRemoteAIAccountBalance
            )
        )
    }

    @State private var isShowingMetricsInfo: Bool = false
    @State private var isShowingLanguagePicker: Bool = false

    private struct LanguageChoice: Identifiable {
        let id: String
        let title: String
        let languageIdentifier: String?
    }

    private var activeFilePath: String? {
        appState.fileEditor.selectedFile
    }

    private var activeLanguageLabel: String {
        guard let filePath = activeFilePath else { return "" }
        let effective = appState.effectiveLanguageIdentifier(
            forAbsoluteFilePath: filePath
        )
        return displayName(for: effective)
    }

    private var languageChoices: [LanguageChoice] {
        var choices: [LanguageChoice] = []
        choices.append(
            LanguageChoice(
                id: "auto",
                title: NSLocalizedString("status.language_mode.auto_detect", comment: ""),
                languageIdentifier: nil
            )
        )

        // Core friendly list (keep simple; include React variants for common mis-detections).
        choices.append(LanguageChoice(id: "swift", title: "Swift", languageIdentifier: "swift"))
        choices.append(LanguageChoice(id: "javascript", title: "JavaScript", languageIdentifier: "javascript"))
        choices.append(LanguageChoice(id: "jsx", title: "JavaScript React", languageIdentifier: "jsx"))
        choices.append(LanguageChoice(id: "typescript", title: "TypeScript", languageIdentifier: "typescript"))
        choices.append(LanguageChoice(id: "tsx", title: "TypeScript React", languageIdentifier: "tsx"))
        choices.append(LanguageChoice(id: "python", title: "Python", languageIdentifier: "python"))
        choices.append(LanguageChoice(id: "php", title: "PHP", languageIdentifier: "php"))
        choices.append(LanguageChoice(id: "html", title: "HTML", languageIdentifier: "html"))
        choices.append(LanguageChoice(id: "css", title: "CSS", languageIdentifier: "css"))
        choices.append(LanguageChoice(id: "json", title: "JSON", languageIdentifier: "json"))
        choices.append(LanguageChoice(id: "yaml", title: "YAML", languageIdentifier: "yaml"))
        choices.append(LanguageChoice(id: "markdown", title: "Markdown", languageIdentifier: "markdown"))
        choices.append(LanguageChoice(id: "text", title: "Plain Text", languageIdentifier: "text"))

        return choices
    }

    private func displayName(for languageIdentifier: String) -> String {
        let normalizedIdentifier = languageIdentifier.lowercased()
        let displayNamesByIdentifier: [String: String] = [
            "swift": "Swift",
            "javascript": "JavaScript",
            "jsx": "JavaScript React",
            "typescript": "TypeScript",
            "tsx": "TypeScript React",
            "python": "Python",
            "php": "PHP",
            "phtml": "PHP",
            "html": "HTML",
            "css": "CSS",
            "json": "JSON",
            "yaml": "YAML",
            "yml": "YAML",
            "markdown": "Markdown",
            "md": "Markdown",
            "text": "Plain Text"
        ]

        return displayNamesByIdentifier[normalizedIdentifier] ?? "Plain Text"
    }

    // MARK: - Legacy text strip (developer mode)

    @ViewBuilder
    private func statusLabel(_ text: String, layoutPriority: Double = 0) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(layoutPriority)
                .help(tooltip(for: text))
        }
    }

    private func tooltip(for text: String) -> String {
        if text.hasPrefix("IDX") { return "Code symbol index — files indexed / total project files" }
        if text.hasPrefix("VS") { return "Vector Store — FAISS-based conversation history RAG" }
        if text.hasPrefix("AC") { return "Auto Complete — inline code completion via local FIM model. OK = model loaded and ready, WIP = generating, - = not installed" }
        if text.hasPrefix("C ") || text.hasPrefix("C\t") { return "Class count in symbol index" }
        if text.hasPrefix("F ") { return "Function count in symbol index" }
        if text.hasPrefix("S ") { return "Total symbol count in index" }
        if text.hasPrefix("Q ") { return "Average quality score of indexed files" }
        if text.hasPrefix("CTX") { return "Context window usage (current / max tokens)" }
        if text.hasPrefix("RAG:") { return "Retrieval-Augmented Generation — searching codebase context" }
        if text.hasPrefix("Indexing") { return "Building code symbol index..." }
        if text.contains("Index: unavailable") { return "Code index database not yet initialized" }
        return ""
    }

    private func statusTooltip(_ text: String) -> String {
        if text.hasPrefix("Indexing") || text.hasPrefix("RAG:") { return tooltip(for: text) }
        if text.contains("Index: unavailable") { return tooltip(for: text) }
        return "IDX: symbol index | VS: conversation history RAG | AC: auto-complete"
    }

    // MARK: - Icon-first strip

    /// Index state color: green normal, orange indexing.
    private var indexStateColor: Color {
        viewModel.isIndexing ? AppConstants.Color.statusWarning : AppConstants.Color.statusSuccess
    }

    /// Vector-store state color: red error, orange ingesting, green loaded, gray uninitialized.
    private var vectorStoreStateColor: Color {
        if viewModel.vectorStoreError { return AppConstants.Color.statusError }
        if viewModel.isIngesting { return AppConstants.Color.statusWarning }
        if viewModel.vectorStoreIsLoaded { return AppConstants.Color.statusSuccess }
        return AppConstants.Color.statusIdle
    }

    /// Auto-complete state color: orange generating, green ready, gray not installed.
    private var acStateColor: Color {
        if !viewModel.isFIMAvailable { return AppConstants.Color.statusIdle }
        return viewModel.fimCompletionStatus == .generating
            ? AppConstants.Color.statusWarning
            : AppConstants.Color.statusSuccess
    }

    /// Session metric (speed/cost/balance) — appears only while it has data.
    @ViewBuilder
    private func sessionMetric(
        symbol: String,
        text: String,
        tooltip: String,
        layoutPriority: Double = 0
    ) -> some View {
        if !text.isEmpty {
            HStack(spacing: AppConstants.Layout.spacingXXS) {
                Image(systemName: symbol)
                    .font(.system(size: AppConstants.Layout.compactIconSize))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(layoutPriority)
            }
            .help(tooltip)
        }
    }

    /// One Tier-1 health item: icon + compact value + state dot.
    private func healthItem(
        symbol: String,
        value: String,
        stateColor: Color,
        tooltip: String,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: AppConstants.Layout.spacingXXS) {
            Image(systemName: symbol)
                .font(.system(size: AppConstants.Layout.compactIconSize))
                .foregroundStyle(.secondary)
            if !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
        }
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }

    // MARK: - Diagnostics popover

    private var contextText: String {
        viewModel.openRouterContextUsageText.isEmpty
            ? viewModel.localModelContextUsageText
            : viewModel.openRouterContextUsageText
    }

    @ViewBuilder
    private func diagnosticsRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            Image(systemName: symbol)
                .font(.system(size: AppConstants.Layout.compactIconSize))
                .foregroundStyle(.secondary)
                .frame(width: AppConstants.Layout.compactIconSize + 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, AppConstants.Layout.spacingXXS)
    }

    @ViewBuilder
    private var diagnosticsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
                HStack(spacing: AppConstants.Layout.spacingSm) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("status.diagnostics.title", comment: ""))
                        .font(.headline)
                    Spacer(minLength: 0)
                }

                if let breakdown = viewModel.symbolBreakdown {
                    Section {
                        Text(NSLocalizedString("status.diagnostics.index_section", comment: ""))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        diagnosticsRow(
                            symbol: "books.vertical",
                            label: NSLocalizedString("status.diagnostics.files", comment: ""),
                            value: breakdown.totalFiles > 0
                                ? "\(breakdown.indexedFiles)/\(breakdown.totalFiles)"
                                : "\(breakdown.indexedFiles)"
                        )
                        diagnosticsRow(symbol: "curlybraces", label: NSLocalizedString("status.diagnostics.classes", comment: ""), value: "\(breakdown.classCount)")
                        diagnosticsRow(symbol: "function", label: NSLocalizedString("status.diagnostics.functions", comment: ""), value: "\(breakdown.functionCount)")
                        diagnosticsRow(symbol: "square.stack.3d.up", label: NSLocalizedString("status.diagnostics.structs", comment: ""), value: "\(breakdown.structCount)")
                        diagnosticsRow(symbol: "tray.full", label: NSLocalizedString("status.diagnostics.enums", comment: ""), value: "\(breakdown.enumCount)")
                        diagnosticsRow(symbol: "square.on.square", label: NSLocalizedString("status.diagnostics.protocols", comment: ""), value: "\(breakdown.protocolCount)")
                        diagnosticsRow(symbol: "variable", label: NSLocalizedString("status.diagnostics.variables", comment: ""), value: "\(breakdown.variableCount)")
                        diagnosticsRow(symbol: "signature", label: NSLocalizedString("status.diagnostics.symbols", comment: ""), value: "\(breakdown.symbolCount)")
                        if breakdown.qualityScore > 0 {
                            diagnosticsRow(
                                symbol: "star",
                                label: NSLocalizedString("status.diagnostics.quality", comment: ""),
                                value: String(format: "%.0f", breakdown.qualityScore)
                            )
                        }
                        diagnosticsRow(
                            symbol: "internaldrive",
                            label: NSLocalizedString("status.diagnostics.index_size", comment: ""),
                            value: formatBytes(breakdown.databaseSizeBytes)
                        )
                    }

                    Divider()

                    Section {
                        Text(NSLocalizedString("status.diagnostics.vector_section", comment: ""))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        let vsState: String = {
                            if breakdown.vectorStoreError { return NSLocalizedString("status.diagnostics.vector_error", comment: "") }
                            if breakdown.isIngesting { return "\(breakdown.ingestionProgress)/\(breakdown.ingestionTotal)" }
                            return breakdown.vectorStoreIsLoaded
                                ? "\(breakdown.vectorStoreEntryCount)"
                                : NSLocalizedString("status.diagnostics.vector_uninit", comment: "")
                        }()
                        diagnosticsRow(symbol: "cylinder", label: NSLocalizedString("status.diagnostics.vector_entries", comment: ""), value: vsState)
                    }

                    Divider()
                }

                Section {
                    Text(NSLocalizedString("status.diagnostics.session_section", comment: ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    diagnosticsRow(symbol: "rectangle.compress.vertical", label: NSLocalizedString("status.diagnostics.context", comment: ""), value: contextText.isEmpty ? "–" : contextText)
                    diagnosticsRow(symbol: "gauge", label: NSLocalizedString("status.diagnostics.speed", comment: ""), value: viewModel.generationSpeedText.isEmpty ? "–" : viewModel.generationSpeedText)
                    diagnosticsRow(symbol: "dollarsign.circle", label: NSLocalizedString("status.diagnostics.cost", comment: ""), value: viewModel.remoteAICostText.isEmpty ? "–" : viewModel.remoteAICostText)
                    diagnosticsRow(symbol: "arrow.up.circle", label: NSLocalizedString("status.diagnostics.spend", comment: ""), value: viewModel.remoteAISpendText.isEmpty ? "–" : viewModel.remoteAISpendText)
                    diagnosticsRow(symbol: "creditcard", label: NSLocalizedString("status.diagnostics.balance", comment: ""), value: viewModel.remoteAIBalanceText.isEmpty ? "–" : viewModel.remoteAIBalanceText)
                }
            }
            .padding(AppConstants.Layout.spacingMd)
        }
        .frame(width: 300, height: 360)
        .nativeGlassBackground(.popover, cornerRadius: AppConstants.Layout.cornerMd)
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

    // MARK: - Language picker

    @ViewBuilder
    private var languagePicker: some View {
        if activeFilePath != nil {
            Button {
                isShowingLanguagePicker.toggle()
            } label: {
                Text(activeLanguageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingLanguagePicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
                    Text(NSLocalizedString("status.language_mode.select_title", comment: ""))
                        .font(.headline)

                    VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
                        ForEach(languageChoices) { choice in
                            Button {
                                guard let filePath = activeFilePath else { return }
                                appState.setLanguageOverride(
                                    forAbsoluteFilePath: filePath,
                                    languageIdentifier: choice.languageIdentifier
                                )
                                isShowingLanguagePicker = false
                            } label: {
                                Text(choice.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(AppConstants.Layout.spacingMd)
                .frame(width: 240)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: AppConstants.Layout.spacingMd) {
            if verboseMetrics {
                legacyContent
            } else {
                iconContent
            }
        }
        .padding(.horizontal, AppConstants.Layout.controlHPadding)
        .frame(height: AppConstants.Layout.statusBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.statusBar)
        .background(AppConstants.Color.surfaceBackground)
        .overlay(alignment: .top) { IDESectionDivider() }
    }

    // MARK: - Legacy (verbose) content

    @ViewBuilder
    private var legacyContent: some View {
        if viewModel.isIndexing {
            ProgressView()
                .controlSize(.small)
        }

        if viewModel.isDownloadingFIM {
            ProgressView(value: viewModel.fimDownloadFraction)
                .progressViewStyle(.linear)
                .frame(width: 80)
            Text("Completion model \(Int(viewModel.fimDownloadFraction * 100))%")
                .font(.caption)
        } else {
            Text(viewModel.statusText)
                .font(.caption)
                .lineLimit(1)
                .help(statusTooltip(viewModel.statusText))
        }

        Spacer(minLength: AppConstants.Layout.spacingSm)

        languagePicker

        HStack(spacing: AppConstants.Layout.statusItemSpacing) {
            // Show remote context when available (API-reported tokens), fall back to local estimate
            let contextText = viewModel.openRouterContextUsageText.isEmpty
                ? viewModel.localModelContextUsageText
                : viewModel.openRouterContextUsageText
            statusLabel(contextText)
            statusLabel(viewModel.remoteAICostText)
            statusLabel(viewModel.remoteAISpendText, layoutPriority: 1)
            statusLabel(viewModel.remoteAIBalanceText, layoutPriority: 1)
            statusLabel(viewModel.generationSpeedText)
            statusLabel(viewModel.metricsText)

            Button {
                isShowingMetricsInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingMetricsInfo, arrowEdge: .bottom) {
                legacyMetricsPopover
            }
        }
    }

    private var legacyMetricsPopover: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            Text(NSLocalizedString("status.metrics.title", comment: ""))
                .font(.headline)
            Text(NSLocalizedString("status.metrics.c", comment: ""))
            Text(NSLocalizedString("status.metrics.f", comment: ""))
            Text(NSLocalizedString("status.metrics.s", comment: ""))
            Text(NSLocalizedString("status.metrics.q", comment: ""))
            Text(NSLocalizedString("status.metrics.m", comment: ""))
            Text(NSLocalizedString("status.metrics.db", comment: ""))
        }
        .padding(AppConstants.Layout.spacingMd)
        .frame(width: 260)
    }

    // MARK: - Icon-first content

    @ViewBuilder
    private var iconContent: some View {
        if viewModel.isIndexing {
            ProgressView()
                .controlSize(.small)
        }

        if viewModel.isDownloadingFIM {
            ProgressView(value: viewModel.fimDownloadFraction)
                .progressViewStyle(.linear)
                .frame(width: 80)
            Text("\(Int(viewModel.fimDownloadFraction * 100))%")
                .font(.caption)
        } else if viewModel.symbolBreakdown != nil || viewModel.isIndexing {
            healthItem(
                symbol: "books.vertical",
                value: viewModel.isIndexing ? "" : viewModel.indexFilesText,
                stateColor: indexStateColor,
                tooltip: "Code symbol index — files indexed / total project files",
                accessibilityLabel: "Code index"
            )
        }

        healthItem(
            symbol: "cylinder",
            value: viewModel.vectorStoreCountText,
            stateColor: vectorStoreStateColor,
            tooltip: "Conversation history RAG store — entries / state",
            accessibilityLabel: "Vector store"
        )

        healthItem(
            symbol: "sparkles",
            value: "",
            stateColor: acStateColor,
            tooltip: "Inline completion model — OK = ready, WIP = generating, – = not installed",
            accessibilityLabel: "Auto-complete"
        )

        Spacer(minLength: AppConstants.Layout.spacingSm)

        languagePicker

        HStack(spacing: AppConstants.Layout.statusItemSpacing) {
            sessionMetric(
                symbol: "rectangle.compress.vertical",
                text: contextText,
                tooltip: "Context window usage (current / max tokens)"
            )
            sessionMetric(
                symbol: "gauge",
                text: viewModel.generationSpeedText,
                tooltip: "Tokens per second"
            )
            sessionMetric(
                symbol: "dollarsign.circle",
                text: viewModel.remoteAICostText,
                tooltip: "Last run cost",
                layoutPriority: 1
            )
            sessionMetric(
                symbol: "creditcard",
                text: viewModel.remoteAIBalanceText,
                tooltip: "Provider account balance",
                layoutPriority: 1
            )

            Button {
                isShowingMetricsInfo.toggle()
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: AppConstants.Layout.compactIconSize))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Index & vector-store analytics")
            .accessibilityLabel("Index analytics")
            .popover(isPresented: $isShowingMetricsInfo, arrowEdge: .bottom) {
                diagnosticsPopover
            }
        }
    }
}
