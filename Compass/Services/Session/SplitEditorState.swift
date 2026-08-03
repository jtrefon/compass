import Foundation

public struct SplitEditorState: Codable, Sendable {
    public var isSplitEditor: Bool
    public var splitAxisRawValue: String
    public var focusedEditorPaneRawValue: String
    public var primaryOpenTabRelativePaths: [String]
    public var primaryActiveTabRelativePath: String?
    public var secondaryOpenTabRelativePaths: [String]
    public var secondaryActiveTabRelativePath: String?

    public init(
        isSplitEditor: Bool = false,
        splitAxisRawValue: String = "vertical",
        focusedEditorPaneRawValue: String = "primary",
        primaryOpenTabRelativePaths: [String] = [],
        primaryActiveTabRelativePath: String? = nil,
        secondaryOpenTabRelativePaths: [String] = [],
        secondaryActiveTabRelativePath: String? = nil
    ) {
        self.isSplitEditor = isSplitEditor
        self.splitAxisRawValue = splitAxisRawValue
        self.focusedEditorPaneRawValue = focusedEditorPaneRawValue
        self.primaryOpenTabRelativePaths = primaryOpenTabRelativePaths
        self.primaryActiveTabRelativePath = primaryActiveTabRelativePath
        self.secondaryOpenTabRelativePaths = secondaryOpenTabRelativePaths
        self.secondaryActiveTabRelativePath = secondaryActiveTabRelativePath
    }
}
