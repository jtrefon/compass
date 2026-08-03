import Foundation

@MainActor
protocol UIServiceProtocol {
    func loadSettings() -> UISettings
    func saveSettings(_ settings: UISettings)
    func resetToDefaults()
    func setTheme(_ theme: AppTheme)
    func setFontSize(_ size: Double)
    func setFontFamily(_ family: String)
    func setIndentationStyle(_ style: IndentationStyle)
    func setCliTimeoutSeconds(_ seconds: Double)
    func setAgentMemoryEnabled(_ enabled: Bool)
    func setAgentQAReviewEnabled(_ enabled: Bool)
    func setShowLineNumbers(_ show: Bool)
    func setWordWrap(_ wrap: Bool)
    func setMinimapVisible(_ visible: Bool)
    func setInlineCompletionEnabled(_ enabled: Bool)
    func setInlineCompletionDebounceMilliseconds(_ milliseconds: Int)
    func setInlineCompletionAggressiveness(_ aggressiveness: Double)
    func setInlineCompletionMaxSuggestionLength(_ length: Int)
    func setInlineCompletionMultilineEnabled(_ enabled: Bool)
    func setInlineCompletionRetrievalEnabled(_ enabled: Bool)
    func setInlineCompletionRoutingMode(_ mode: InlineCompletionRoutingMode)
    func setInlineCompletionDebugOverlayEnabled(_ enabled: Bool)
    func setSidebarWidth(_ width: Double)
    func setTerminalHeight(_ height: Double)
    func setChatPanelWidth(_ width: Double)
    func setBottomPanelSelectedName(_ name: String)

    // Terminal settings
    func setTerminalFontSize(_ size: Double)
    func setTerminalFontFamily(_ family: String)
    func setTerminalForegroundColor(_ color: String)
    func setTerminalBackgroundColor(_ color: String)
    func setTerminalShell(_ shell: String)

    func exportSettings() -> [String: Any]
    func importSettings(_ settings: [String: Any])
}
