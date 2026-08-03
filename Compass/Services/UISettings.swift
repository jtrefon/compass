import Foundation

struct UISettings {
    let selectedTheme: AppTheme
    let fontSize: Double
    let fontFamily: String
    let indentationStyle: IndentationStyle
    let cliTimeoutSeconds: Double
    let agentMemoryEnabled: Bool
    let agentQAReviewEnabled: Bool
    let showLineNumbers: Bool
    let wordWrap: Bool
    let minimapVisible: Bool
    let inlineCompletionEnabled: Bool
    let inlineCompletionDebounceMilliseconds: Int
    let inlineCompletionAggressiveness: Double
    let inlineCompletionMaxSuggestionLength: Int
    let inlineCompletionMultilineEnabled: Bool
    let inlineCompletionRetrievalEnabled: Bool
    let inlineCompletionRoutingMode: InlineCompletionRoutingMode
    let inlineCompletionDebugOverlayEnabled: Bool
    let sidebarWidth: Double
    let terminalHeight: Double
    let chatPanelWidth: Double
    let bottomPanelSelectedName: String

    // Terminal settings
    let terminalFontSize: Double
    let terminalFontFamily: String
    let terminalForegroundColor: String
    let terminalBackgroundColor: String
    let terminalShell: String
}
