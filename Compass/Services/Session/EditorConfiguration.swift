import Foundation

public struct EditorConfiguration: Codable, Sendable {
    public var selectedThemeRawValue: String
    public var showLineNumbers: Bool
    public var wordWrap: Bool
    public var minimapVisible: Bool
    public var showHiddenFilesInFileTree: Bool

    public init(
        selectedThemeRawValue: String = "system",
        showLineNumbers: Bool = true,
        wordWrap: Bool = false,
        minimapVisible: Bool = false,
        showHiddenFilesInFileTree: Bool = false
    ) {
        self.selectedThemeRawValue = selectedThemeRawValue
        self.showLineNumbers = showLineNumbers
        self.wordWrap = wordWrap
        self.minimapVisible = minimapVisible
        self.showHiddenFilesInFileTree = showHiddenFilesInFileTree
    }
}
