//
//  UIStateManager.swift
//  Compass
//
//  Created by Jack Trefon on 20/12/2025.
//

import SwiftUI
import Combine
import AppKit

/// Manages UI state and layout preferences
@MainActor
class UIStateManager: ObservableObject {
    // MARK: - Layout State

    @Published var isSidebarVisible: Bool = true {
        didSet { trackChange("isSidebarVisible", from: oldValue, to: isSidebarVisible) }
    }
    @Published var isTerminalVisible: Bool = true {
        didSet { trackChange("isTerminalVisible", from: oldValue, to: isTerminalVisible) }
    }
    @Published var isAIChatVisible: Bool = true {
        didSet { trackChange("isAIChatVisible", from: oldValue, to: isAIChatVisible) }
    }
    @Published var isCodePanelVisible: Bool = true {
        didSet { trackChange("isCodePanelVisible", from: oldValue, to: isCodePanelVisible) }
    }
    @Published var bottomPanelSelectedName: String = AppConstants.Overlay.internalTerminalPanelName {
        didSet { trackChange("bottomPanelSelectedName", from: oldValue, to: bottomPanelSelectedName) }
    }
    @Published var sidebarWidth: Double = AppConstants.Layout.defaultSidebarWidth {
        didSet { trackChange("sidebarWidth", from: oldValue, to: sidebarWidth) }
    }
    @Published var terminalHeight: Double = AppConstants.Layout.defaultTerminalHeight {
        didSet { trackChange("terminalHeight", from: oldValue, to: terminalHeight) }
    }
    @Published var chatPanelWidth: Double = AppConstants.Layout.defaultChatPanelWidth {
        didSet { trackChange("chatPanelWidth", from: oldValue, to: chatPanelWidth) }
    }

    // MARK: - Editor State

    @Published var showLineNumbers: Bool = true {
        didSet { trackChange("showLineNumbers", from: oldValue, to: showLineNumbers) }
    }
    @Published var wordWrap: Bool = false {
        didSet { trackChange("wordWrap", from: oldValue, to: wordWrap) }
    }
    @Published var minimapVisible: Bool = false {
        didSet { trackChange("minimapVisible", from: oldValue, to: minimapVisible) }
    }
    @Published var inlineCompletionEnabled: Bool = InlineCompletionSettings.default.isEnabled {
        didSet { trackChange("inlineCompletionEnabled", from: oldValue, to: inlineCompletionEnabled) }
    }
    @Published var inlineCompletionAggressiveness: Double = InlineCompletionSettings.default.aggressiveness {
        didSet { trackChange("inlineCompletionAggressiveness", from: oldValue, to: inlineCompletionAggressiveness) }
    }
    @Published var inlineCompletionMaxSuggestionLength: Int = InlineCompletionSettings.default.maxSuggestionLength {
        didSet { trackChange("inlineCompletionMaxSuggestionLength", from: oldValue, to: inlineCompletionMaxSuggestionLength) }
    }
    @Published var inlineCompletionDebugOverlayEnabled: Bool = InlineCompletionSettings.default.debugOverlayEnabled {
        didSet { trackChange("inlineCompletionDebugOverlayEnabled", from: oldValue, to: inlineCompletionDebugOverlayEnabled) }
    }
    @Published var fontSize: Double = AppConstants.Editor.defaultFontSize {
        didSet { trackChange("fontSize", from: oldValue, to: fontSize) }
    }
    @Published var fontFamily: String = AppConstants.Editor.defaultFontFamily {
        didSet { trackChange("fontFamily", from: oldValue, to: fontFamily) }
    }
    @Published var indentationStyle: IndentationStyle = .tabs {
        didSet { trackChange("indentationStyle", from: String(describing: oldValue), to: String(describing: indentationStyle)) }
    }

    // MARK: - Terminal Settings

    @Published var terminalFontSize: Double = 12
    @Published var terminalFontFamily: String = "SF Mono"
    @Published var terminalForegroundColor: String = "#D4D4D4" // Light gray
    @Published var terminalBackgroundColor: String = "#1E1E1E" // Dark gray
    @Published var terminalShell: String = "/bin/zsh"

    // MARK: - Agent Settings

    @Published var cliTimeoutSeconds: Double = 30
    @Published var agentMemoryEnabled: Bool = true
    @Published var agentQAReviewEnabled: Bool = false

    // MARK: - Theme State

    @Published var selectedTheme: AppTheme = .system

    // MARK: - Services

    private let uiService: UIServiceProtocol
    private let eventBus: EventBusProtocol
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Diagnostics
    
    private var changeCounts: [String: Int] = [:]
    private var lastChangeTime: [String: Date] = [:]

    init(uiService: UIServiceProtocol, eventBus: EventBusProtocol) {
        self.uiService = uiService
        self.eventBus = eventBus
        loadSettings()
        setupEventSubscriptions()
    }
    
    private func trackChange<T>(_ name: String, from: T, to: T) where T: Equatable {
        guard from != to else { return }

        let count = (changeCounts[name] ?? 0) + 1
        changeCounts[name] = count

        let now = Date()
        lastChangeTime[name] = now

        // Log every 10 changes so rapid UI toggling remains auditable.
        if count % 10 == 0 {
            Task {
                await AppLogger.shared.debug(
                    category: .app,
                    message: "ui.state_changed",
                    context: AppLogger.LogCallContext(metadata: [
                        "name": name,
                        "changeCount": count,
                    ])
                )
            }
        }
    }

    private func setupEventSubscriptions() {
        eventBus.subscribe(to: TerminalHeightChangedEvent.self) { [weak self] event in
            self?.terminalHeight = event.height
        }.store(in: &cancellables)
    }

    // MARK: - Layout Management

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
    }

    func updateSidebarWidth(_ width: Double) {
        sidebarWidth = max(AppConstants.Layout.minSidebarWidth, width)
        uiService.setSidebarWidth(sidebarWidth)
    }

    func updateTerminalHeight(_ height: Double) {
        terminalHeight = max(AppConstants.Layout.minTerminalHeight, height)
        uiService.setTerminalHeight(terminalHeight)
    }

    func updateChatPanelWidth(_ width: Double) {
        chatPanelWidth = max(AppConstants.Layout.minChatPanelWidth, width)
        uiService.setChatPanelWidth(chatPanelWidth)
    }

    // MARK: - Editor Settings

    func setShowLineNumbers(_ show: Bool) {
        showLineNumbers = show
        uiService.setShowLineNumbers(show)
    }

    func setWordWrap(_ wrap: Bool) {
        wordWrap = wrap
        uiService.setWordWrap(wrap)
    }

    func toggleMinimap() {
        minimapVisible.toggle()
        uiService.setMinimapVisible(minimapVisible)
    }

    func setMinimapVisible(_ visible: Bool) {
        minimapVisible = visible
        uiService.setMinimapVisible(visible)
    }

    func setInlineCompletionEnabled(_ enabled: Bool) {
        inlineCompletionEnabled = enabled
        uiService.setInlineCompletionEnabled(enabled)
    }

    func setInlineCompletionAggressiveness(_ aggressiveness: Double) {
        inlineCompletionAggressiveness = max(0.05, min(1.0, aggressiveness))
        uiService.setInlineCompletionAggressiveness(inlineCompletionAggressiveness)
    }

    func setInlineCompletionMaxSuggestionLength(_ length: Int) {
        inlineCompletionMaxSuggestionLength = max(16, min(512, length))
        uiService.setInlineCompletionMaxSuggestionLength(inlineCompletionMaxSuggestionLength)
    }

    func setInlineCompletionDebugOverlayEnabled(_ enabled: Bool) {
        inlineCompletionDebugOverlayEnabled = enabled
        uiService.setInlineCompletionDebugOverlayEnabled(enabled)
    }

    func updateFontSize(_ size: Double) {
        guard size >= AppConstants.Editor.minFontSize && size <= AppConstants.Editor.maxFontSize else { return }
        fontSize = size
        uiService.setFontSize(size)
    }

    func updateFontFamily(_ family: String) {
        fontFamily = family
        uiService.setFontFamily(family)
    }

    func setIndentationStyle(_ style: IndentationStyle) {
        indentationStyle = style
        uiService.setIndentationStyle(style)
    }

    // MARK: - Theme Management

    func setTheme(_ theme: AppTheme) {
        selectedTheme = theme
        uiService.setTheme(theme)
    }

    func setCliTimeoutSeconds(_ seconds: Double) {
        let clamped = max(1, min(300, seconds))
        cliTimeoutSeconds = clamped
        uiService.setCliTimeoutSeconds(clamped)
    }

    func setAgentMemoryEnabled(_ enabled: Bool) {
        agentMemoryEnabled = enabled
        uiService.setAgentMemoryEnabled(enabled)
    }

    func setAgentQAReviewEnabled(_ enabled: Bool) {
        agentQAReviewEnabled = enabled
        uiService.setAgentQAReviewEnabled(enabled)
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        let settings = uiService.loadSettings()
        selectedTheme = settings.selectedTheme
        fontSize = settings.fontSize
        fontFamily = settings.fontFamily
        indentationStyle = settings.indentationStyle
        cliTimeoutSeconds = settings.cliTimeoutSeconds
        agentMemoryEnabled = settings.agentMemoryEnabled
        agentQAReviewEnabled = settings.agentQAReviewEnabled
        showLineNumbers = settings.showLineNumbers
        wordWrap = settings.wordWrap
        minimapVisible = settings.minimapVisible
        inlineCompletionEnabled = settings.inlineCompletionEnabled
        inlineCompletionAggressiveness = settings.inlineCompletionAggressiveness
        inlineCompletionMaxSuggestionLength = settings.inlineCompletionMaxSuggestionLength
        inlineCompletionDebugOverlayEnabled = settings.inlineCompletionDebugOverlayEnabled
        sidebarWidth = settings.sidebarWidth
        terminalHeight = settings.terminalHeight
        chatPanelWidth = settings.chatPanelWidth
        bottomPanelSelectedName = settings.bottomPanelSelectedName

        // Load terminal settings
        terminalFontSize = settings.terminalFontSize
        terminalFontFamily = settings.terminalFontFamily
        terminalForegroundColor = settings.terminalForegroundColor
        terminalBackgroundColor = settings.terminalBackgroundColor
        terminalShell = settings.terminalShell
    }

    func resetToDefaults() {
        uiService.resetToDefaults()

        // Reset local state to defaults
        isSidebarVisible = true
        isTerminalVisible = true
        isAIChatVisible = true
        isCodePanelVisible = true
        sidebarWidth = AppConstants.Layout.defaultSidebarWidth
        terminalHeight = AppConstants.Layout.defaultTerminalHeight
        chatPanelWidth = AppConstants.Layout.defaultChatPanelWidth
        showLineNumbers = true
        wordWrap = false
        minimapVisible = false
        inlineCompletionEnabled = InlineCompletionSettings.default.isEnabled
        inlineCompletionAggressiveness = InlineCompletionSettings.default.aggressiveness
        inlineCompletionMaxSuggestionLength = InlineCompletionSettings.default.maxSuggestionLength
        inlineCompletionDebugOverlayEnabled = InlineCompletionSettings.default.debugOverlayEnabled
        fontSize = AppConstants.Editor.defaultFontSize
        fontFamily = AppConstants.Editor.defaultFontFamily
        indentationStyle = .tabs
        cliTimeoutSeconds = 30
        agentMemoryEnabled = true
        selectedTheme = .system

        // Reset terminal settings to defaults
        terminalFontSize = 12
        terminalFontFamily = "SF Mono"
        terminalForegroundColor = "#D4D4D4" // Light gray
        terminalBackgroundColor = "#1E1E1E" // Dark gray
        terminalShell = "/bin/zsh"
    }

    // MARK: - Settings Export/Import

    func exportSettings() -> [String: Any] {
        return uiService.exportSettings()
    }

    func importSettings(_ settings: [String: Any]) {
        uiService.importSettings(settings)
        loadSettings() // Refresh local state
    }
}
