//
//  UIService.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import Foundation
import SwiftUI

/// Persists global UI settings to UserDefaults.
@MainActor
final class UIService: UIServiceProtocol {
    private let errorManager: any ErrorManagerProtocol
    private let eventBus: any EventBusProtocol
    private let settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)

    init(errorManager: any ErrorManagerProtocol, eventBus: any EventBusProtocol) {
        self.errorManager = errorManager
        self.eventBus = eventBus
    }

    // MARK: - Theme Management

    /// Change application theme
    func setTheme(_ theme: AppTheme) {
        // Project-scoped setting. Persisted via .ide/session.json
    }

    // MARK: - Font Settings

    /// Update font size
    func setFontSize(_ size: Double) {
        guard size >= AppConstantsEditor.minFontSize && size <= AppConstantsEditor.maxFontSize else {
            errorManager.handle(.invalidFilePath("Font size must be between \(AppConstantsEditor.minFontSize) and \(AppConstantsEditor.maxFontSize)"))
            return
        }
        settingsStore.set(size, forKey: AppConstantsStorage.fontSizeKey)
    }

    /// Update font family
    func setFontFamily(_ family: String) {
        settingsStore.set(family, forKey: AppConstantsStorage.fontFamilyKey)
    }

    // MARK: - Indentation

    func setIndentationStyle(_ style: IndentationStyle) {
        settingsStore.set(style.rawValue, forKey: AppConstantsStorage.indentationStyleKey)
    }

    func setCliTimeoutSeconds(_ seconds: Double) {
        let clamped = max(5, min(120, seconds))
        settingsStore.set(clamped, forKey: AppConstantsStorage.cliTimeoutSecondsKey)
    }

    func setAgentMemoryEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: AppConstantsStorage.agentMemoryEnabledKey)
    }

    func setAgentQAReviewEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: AppConstantsStorage.agentQAReviewEnabledKey)
    }

    // MARK: - Editor Settings

    /// Toggle line numbers visibility
    func setShowLineNumbers(_ show: Bool) {
        // Project-scoped setting. Persisted via .ide/session.json
    }

    /// Toggle word wrap
    func setWordWrap(_ wrap: Bool) {
        // Project-scoped setting. Persisted via .ide/session.json
    }

    /// Toggle minimap visibility
    func setMinimapVisible(_ visible: Bool) {
        // Project-scoped setting. Persisted via .ide/session.json
    }

    func setInlineCompletionEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: AppConstantsStorage.inlineCompletionEnabledKey)
    }

    func setInlineCompletionDebounceMilliseconds(_ milliseconds: Int) {
        settingsStore.set(max(50, min(800, milliseconds)), forKey: AppConstantsStorage.inlineCompletionDebounceMsKey)
    }

    func setInlineCompletionAggressiveness(_ aggressiveness: Double) {
        settingsStore.set(max(0.05, min(1.0, aggressiveness)), forKey: AppConstantsStorage.inlineCompletionAggressivenessKey)
    }

    func setInlineCompletionMaxSuggestionLength(_ length: Int) {
        settingsStore.set(max(16, min(512, length)), forKey: AppConstantsStorage.inlineCompletionMaxLengthKey)
    }

    func setInlineCompletionDebugOverlayEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: AppConstantsStorage.inlineCompletionDebugOverlayKey)
    }

    // MARK: - Layout Settings

    /// Update sidebar width
    func setSidebarWidth(_ width: Double) {
    }

    /// Update terminal height
    func setTerminalHeight(_ height: Double) {
        eventBus.publish(TerminalHeightChangedEvent(height: height))
    }

    /// Update chat panel width
    func setChatPanelWidth(_ width: Double) {
    }

    func setBottomPanelSelectedName(_ name: String) {
        settingsStore.set(name, forKey: "bottomPanelSelectedName")
    }

    // MARK: - Terminal Settings

    /// Update terminal font size
    func setTerminalFontSize(_ size: Double) {
        settingsStore.set(size, forKey: "terminalFontSize")
    }

    /// Update terminal font family
    func setTerminalFontFamily(_ family: String) {
        settingsStore.set(family, forKey: "terminalFontFamily")
    }

    /// Update terminal foreground color
    func setTerminalForegroundColor(_ color: String) {
        settingsStore.set(color, forKey: "terminalForegroundColor")
    }

    /// Update terminal background color
    func setTerminalBackgroundColor(_ color: String) {
        settingsStore.set(color, forKey: "terminalBackgroundColor")
    }

    /// Update terminal shell
    func setTerminalShell(_ shell: String) {
        settingsStore.set(shell, forKey: "terminalShell")
    }

    // MARK: - Settings Persistence

    /// Load settings from UserDefaults
    func loadSettings() -> UISettings {
        let storedTheme: AppTheme = .system

        let storedFontSize = settingsStore.double(forKey: AppConstantsStorage.fontSizeKey)
        let fontSize = storedFontSize == 0 ? AppConstantsEditor.defaultFontSize : storedFontSize

        let sidebarWidth = AppConstantsLayout.defaultSidebarWidth
        let terminalHeight = AppConstantsLayout.defaultTerminalHeight
        let chatPanelWidth = AppConstantsLayout.defaultChatPanelWidth

        let showLineNumbers: Bool = true
        let wordWrap: Bool = false
        let minimapVisible: Bool = false
        let inlineCompletionSettings = InlineCompletionSettingsStore(settingsStore: settingsStore).load()

        let indentationStyle = IndentationStyle.current(userDefaults: AppRuntimeEnvironment.userDefaults)

        let storedCliTimeout = settingsStore.double(forKey: AppConstantsStorage.cliTimeoutSecondsKey)
        let cliTimeoutSeconds = storedCliTimeout == 0 ? 15 : storedCliTimeout

        let agentMemoryEnabled = settingsStore.bool(forKey: AppConstantsStorage.agentMemoryEnabledKey, default: true)

        let agentQAReviewEnabled = settingsStore.bool(forKey: AppConstantsStorage.agentQAReviewEnabledKey, default: false)

        // Load terminal settings
        let terminalFontSize = settingsStore.double(forKey: "terminalFontSize")
        let terminalFontSizeValue = terminalFontSize == 0 ? 12 : terminalFontSize
        let terminalFontFamily = settingsStore.string(forKey: "terminalFontFamily") ?? "SF Mono"
        let terminalForegroundColor = settingsStore.string(forKey: "terminalForegroundColor") ?? "#D4D4D4"
        let terminalBackgroundColor = settingsStore.string(forKey: "terminalBackgroundColor") ?? "#1E1E1E"
        let terminalShell = settingsStore.string(forKey: "terminalShell") ?? "/bin/zsh"

        let bottomPanel = settingsStore.string(forKey: "bottomPanelSelectedName") ?? AppConstants.Overlay.internalTerminalPanelName

        return UISettings(
            selectedTheme: storedTheme,
            fontSize: fontSize,
            fontFamily: settingsStore.string(forKey: AppConstantsStorage.fontFamilyKey) ?? AppConstantsEditor.defaultFontFamily,
            indentationStyle: indentationStyle,
            cliTimeoutSeconds: cliTimeoutSeconds,
            agentMemoryEnabled: agentMemoryEnabled,
            agentQAReviewEnabled: agentQAReviewEnabled,
            showLineNumbers: showLineNumbers,
            wordWrap: wordWrap,
            minimapVisible: minimapVisible,
            inlineCompletionEnabled: inlineCompletionSettings.isEnabled,
            inlineCompletionDebounceMilliseconds: inlineCompletionSettings.debounceMilliseconds,
            inlineCompletionAggressiveness: inlineCompletionSettings.aggressiveness,
            inlineCompletionMaxSuggestionLength: inlineCompletionSettings.maxSuggestionLength,
            inlineCompletionDebugOverlayEnabled: inlineCompletionSettings.debugOverlayEnabled,
            sidebarWidth: sidebarWidth,
            terminalHeight: terminalHeight,
            chatPanelWidth: chatPanelWidth,
            bottomPanelSelectedName: bottomPanel,
            terminalFontSize: terminalFontSizeValue,
            terminalFontFamily: terminalFontFamily,
            terminalForegroundColor: terminalForegroundColor,
            terminalBackgroundColor: terminalBackgroundColor,
            terminalShell: terminalShell
        )
    }

    /// Save settings to UserDefaults
    func saveSettings(_ settings: UISettings) {
        setTheme(settings.selectedTheme)
        setFontSize(settings.fontSize)
        setFontFamily(settings.fontFamily)
        setIndentationStyle(settings.indentationStyle)
        setCliTimeoutSeconds(settings.cliTimeoutSeconds)
        setAgentMemoryEnabled(settings.agentMemoryEnabled)
        setAgentQAReviewEnabled(settings.agentQAReviewEnabled)
        setShowLineNumbers(settings.showLineNumbers)
        setWordWrap(settings.wordWrap)
        setMinimapVisible(settings.minimapVisible)
        setInlineCompletionEnabled(settings.inlineCompletionEnabled)
        setInlineCompletionDebounceMilliseconds(settings.inlineCompletionDebounceMilliseconds)
        setInlineCompletionAggressiveness(settings.inlineCompletionAggressiveness)
        setInlineCompletionMaxSuggestionLength(settings.inlineCompletionMaxSuggestionLength)
        setInlineCompletionDebugOverlayEnabled(settings.inlineCompletionDebugOverlayEnabled)
        setSidebarWidth(settings.sidebarWidth)
        setTerminalHeight(settings.terminalHeight)
        setChatPanelWidth(settings.chatPanelWidth)
        setBottomPanelSelectedName(settings.bottomPanelSelectedName)

        // Save terminal settings
        setTerminalFontSize(settings.terminalFontSize)
        setTerminalFontFamily(settings.terminalFontFamily)
        setTerminalForegroundColor(settings.terminalForegroundColor)
        setTerminalBackgroundColor(settings.terminalBackgroundColor)
        setTerminalShell(settings.terminalShell)
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        let keys = [
            AppConstantsStorage.fontSizeKey,
            AppConstantsStorage.fontFamilyKey,
            AppConstantsStorage.indentationStyleKey,
            AppConstantsStorage.cliTimeoutSecondsKey,
            AppConstantsStorage.agentMemoryEnabledKey,
            AppConstantsStorage.agentQAReviewEnabledKey,
            AppConstantsStorage.inlineCompletionEnabledKey,
            AppConstantsStorage.inlineCompletionDebounceMsKey,
            AppConstantsStorage.inlineCompletionAggressivenessKey,
            AppConstantsStorage.inlineCompletionMaxLengthKey,
            AppConstantsStorage.inlineCompletionDebugOverlayKey
        ]
        keys.forEach { settingsStore.removeObject(forKey: $0) }
    }

    /// Export all settings as dictionary
    func exportSettings() -> [String: Any] {
        let settings = loadSettings()
        return [
            "selectedTheme": settings.selectedTheme.rawValue,
            "fontSize": settings.fontSize,
            "fontFamily": settings.fontFamily,
            "indentationStyle": settings.indentationStyle.rawValue,
            "cliTimeoutSeconds": settings.cliTimeoutSeconds,
            "agentMemoryEnabled": settings.agentMemoryEnabled,
            "agentQAReviewEnabled": settings.agentQAReviewEnabled,
            "showLineNumbers": settings.showLineNumbers,
            "wordWrap": settings.wordWrap,
            "minimapVisible": settings.minimapVisible,
            "inlineCompletionEnabled": settings.inlineCompletionEnabled,
            "inlineCompletionDebounceMilliseconds": settings.inlineCompletionDebounceMilliseconds,
            "inlineCompletionAggressiveness": settings.inlineCompletionAggressiveness,
            "inlineCompletionMaxSuggestionLength": settings.inlineCompletionMaxSuggestionLength,
            "inlineCompletionDebugOverlayEnabled": settings.inlineCompletionDebugOverlayEnabled,
            "sidebarWidth": settings.sidebarWidth,
            "terminalHeight": settings.terminalHeight,
            "chatPanelWidth": settings.chatPanelWidth,
            "terminalFontSize": settings.terminalFontSize,
            "terminalFontFamily": settings.terminalFontFamily,
            "terminalForegroundColor": settings.terminalForegroundColor,
            "terminalBackgroundColor": settings.terminalBackgroundColor,
            "terminalShell": settings.terminalShell
        ]
    }

    /// Import settings
    func importSettings(_ settings: [String: Any]) {
        applyTheme(from: settings)
        applyFontSize(from: settings)
        applyFontFamily(from: settings)
        applyIndentationStyle(from: settings)
        applyCliTimeoutSeconds(from: settings)
        applyAgentMemoryEnabled(from: settings)
        applyAgentQAReviewEnabled(from: settings)
        applyShowLineNumbers(from: settings)
        applyWordWrap(from: settings)
        applyMinimapVisible(from: settings)
        applyInlineCompletionEnabled(from: settings)
        applyInlineCompletionDebounceMilliseconds(from: settings)
        applyInlineCompletionAggressiveness(from: settings)
        applyInlineCompletionMaxSuggestionLength(from: settings)
        applyInlineCompletionDebugOverlayEnabled(from: settings)
        applySidebarWidth(from: settings)
        applyTerminalHeight(from: settings)
        applyChatPanelWidth(from: settings)

        // Apply terminal settings
        applyTerminalFontSize(from: settings)
        applyTerminalFontFamily(from: settings)
        applyTerminalForegroundColor(from: settings)
        applyTerminalBackgroundColor(from: settings)
        applyTerminalShell(from: settings)
    }

    private func applyTheme(from settings: [String: Any]) {
        guard let themeRaw = settings["theme"] as? String,
              let theme = AppTheme(rawValue: themeRaw) else {
            return
        }
        setTheme(theme)
    }

    private func applyFontSize(from settings: [String: Any]) {
        guard let size = settings["fontSize"] as? Double else { return }
        setFontSize(size)
    }

    private func applyFontFamily(from settings: [String: Any]) {
        guard let family = settings["fontFamily"] as? String else { return }
        setFontFamily(family)
    }

    private func applyIndentationStyle(from settings: [String: Any]) {
        guard let raw = settings["indentationStyle"] as? String,
              let style = IndentationStyle(rawValue: raw) else {
            return
        }
        setIndentationStyle(style)
    }

    private func applyCliTimeoutSeconds(from settings: [String: Any]) {
        guard let timeout = settings["cliTimeoutSeconds"] as? Double else { return }
        setCliTimeoutSeconds(timeout)
    }

    private func applyAgentMemoryEnabled(from settings: [String: Any]) {
        guard let enabled = settings["agentMemoryEnabled"] as? Bool else { return }
        setAgentMemoryEnabled(enabled)
    }

    private func applyAgentQAReviewEnabled(from settings: [String: Any]) {
        guard let enabled = settings["agentQAReviewEnabled"] as? Bool else { return }
        setAgentQAReviewEnabled(enabled)
    }

    private func applyShowLineNumbers(from settings: [String: Any]) {
        guard let show = settings["showLineNumbers"] as? Bool else { return }
        setShowLineNumbers(show)
    }

    private func applyWordWrap(from settings: [String: Any]) {
        guard let wrap = settings["wordWrap"] as? Bool else { return }
        setWordWrap(wrap)
    }

    private func applyMinimapVisible(from settings: [String: Any]) {
        guard let visible = settings["minimapVisible"] as? Bool else { return }
        setMinimapVisible(visible)
    }

    private func applyInlineCompletionEnabled(from settings: [String: Any]) {
        guard let enabled = settings["inlineCompletionEnabled"] as? Bool else { return }
        setInlineCompletionEnabled(enabled)
    }

    private func applyInlineCompletionDebounceMilliseconds(from settings: [String: Any]) {
        guard let milliseconds = settings["inlineCompletionDebounceMilliseconds"] as? Int else { return }
        setInlineCompletionDebounceMilliseconds(milliseconds)
    }

    private func applyInlineCompletionAggressiveness(from settings: [String: Any]) {
        guard let aggressiveness = settings["inlineCompletionAggressiveness"] as? Double else { return }
        setInlineCompletionAggressiveness(aggressiveness)
    }

    private func applyInlineCompletionMaxSuggestionLength(from settings: [String: Any]) {
        guard let length = settings["inlineCompletionMaxSuggestionLength"] as? Int else { return }
        setInlineCompletionMaxSuggestionLength(length)
    }

    private func applyInlineCompletionDebugOverlayEnabled(from settings: [String: Any]) {
        guard let enabled = settings["inlineCompletionDebugOverlayEnabled"] as? Bool else { return }
        setInlineCompletionDebugOverlayEnabled(enabled)
    }

    private func applySidebarWidth(from settings: [String: Any]) {
        guard let width = settings["sidebarWidth"] as? Double else { return }
        setSidebarWidth(width)
    }

    private func applyTerminalHeight(from settings: [String: Any]) {
        guard let height = settings["terminalHeight"] as? Double else { return }
        setTerminalHeight(height)
    }

    private func applyChatPanelWidth(from settings: [String: Any]) {
        guard let width = settings["chatPanelWidth"] as? Double else { return }
        setChatPanelWidth(width)
    }

    // MARK: - Terminal Settings Apply Methods

    private func applyTerminalFontSize(from settings: [String: Any]) {
        guard let size = settings["terminalFontSize"] as? Double else { return }
        setTerminalFontSize(size)
    }

    private func applyTerminalFontFamily(from settings: [String: Any]) {
        guard let family = settings["terminalFontFamily"] as? String else { return }
        setTerminalFontFamily(family)
    }

    private func applyTerminalForegroundColor(from settings: [String: Any]) {
        guard let color = settings["terminalForegroundColor"] as? String else { return }
        setTerminalForegroundColor(color)
    }

    private func applyTerminalBackgroundColor(from settings: [String: Any]) {
        guard let color = settings["terminalBackgroundColor"] as? String else { return }
        setTerminalBackgroundColor(color)
    }

    private func applyTerminalShell(from settings: [String: Any]) {
        guard let shell = settings["terminalShell"] as? String else { return }
        setTerminalShell(shell)
    }
}
