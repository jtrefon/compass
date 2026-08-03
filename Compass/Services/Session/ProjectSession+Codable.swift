import Foundation

extension ProjectSession {
    private enum CodingKeys: String, CodingKey {
        case uiConfiguration = "ui"
        case editor
        case fileState
        case splitEditor
        case fileTree
        case aiModeRawValue

        case windowFrame
        case isSidebarVisible
        case isTerminalVisible
        case isAIChatVisible
        case isCodePanelVisible
        case sidebarWidth
        case terminalHeight
        case chatPanelWidth
        case selectedThemeRawValue
        case showLineNumbers
        case wordWrap
        case minimapVisible
        case showHiddenFilesInFileTree
        case lastOpenFileRelativePath
        case openTabRelativePaths
        case activeTabRelativePath
        case isSplitEditor
        case splitAxisRawValue
        case focusedEditorPaneRawValue
        case primaryOpenTabRelativePaths
        case primaryActiveTabRelativePath
        case secondaryOpenTabRelativePaths
        case secondaryActiveTabRelativePath
        case fileTreeExpandedRelativePaths
        case languageOverridesByRelativePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let decodedSession = try Self.decodeNewFormat(from: container) {
            self = decodedSession
            return
        }

        self = try Self.decodeLegacyFormat(from: container)
    }

    private static func decodeNewFormat(from container: KeyedDecodingContainer<CodingKeys>) throws -> ProjectSession? {
        guard
            let decodedUIConfiguration = try container.decodeIfPresent(UIConfiguration.self, forKey: .uiConfiguration),
            let decodedEditorConfiguration = try container.decodeIfPresent(EditorConfiguration.self, forKey: .editor),
            let decodedFileState = try container.decodeIfPresent(FileState.self, forKey: .fileState),
            let decodedSplitEditorState = try container.decodeIfPresent(SplitEditorState.self, forKey: .splitEditor),
            let decodedFileTreeState = try container.decodeIfPresent(FileTreeState.self, forKey: .fileTree)
        else {
            return nil
        }

        let decodedAIModeRawValue = try container.decodeIfPresent(String.self, forKey: .aiModeRawValue) ?? "Chat"

        return ProjectSession(
            uiConfiguration: decodedUIConfiguration,
            editor: decodedEditorConfiguration,
            fileState: decodedFileState,
            splitEditor: decodedSplitEditorState,
            fileTree: decodedFileTreeState,
            aiModeRawValue: decodedAIModeRawValue
        )
    }

    private static func decodeLegacyFormat(from container: KeyedDecodingContainer<CodingKeys>) throws -> ProjectSession {
        let decodedWindowFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)

        let decodedUIConfiguration = UIConfiguration(
            windowFrame: decodedWindowFrame,
            isSidebarVisible: try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true,
            isTerminalVisible: try container.decodeIfPresent(Bool.self, forKey: .isTerminalVisible) ?? true,
            isAIChatVisible: try container.decodeIfPresent(Bool.self, forKey: .isAIChatVisible) ?? true,
            isCodePanelVisible: try container.decodeIfPresent(Bool.self, forKey: .isCodePanelVisible) ?? true,
            sidebarWidth: try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 250,
            terminalHeight: try container.decodeIfPresent(Double.self, forKey: .terminalHeight) ?? 200,
            chatPanelWidth: try container.decodeIfPresent(Double.self, forKey: .chatPanelWidth) ?? 300
        )

        let decodedEditorConfiguration = try decodeLegacyEditorConfiguration(from: container)
        let decodedFileState = try decodeLegacyFileState(from: container)
        let decodedSplitEditorState = try decodeLegacySplitEditorState(from: container)
        let decodedFileTreeState = try decodeLegacyFileTreeState(from: container)
        let decodedAIModeRawValue = try container.decodeIfPresent(String.self, forKey: .aiModeRawValue) ?? "Chat"

        return ProjectSession(
            uiConfiguration: decodedUIConfiguration,
            editor: decodedEditorConfiguration,
            fileState: decodedFileState,
            splitEditor: decodedSplitEditorState,
            fileTree: decodedFileTreeState,
            aiModeRawValue: decodedAIModeRawValue
        )
    }

    private static func decodeLegacyEditorConfiguration(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EditorConfiguration {
        let decodedThemeRawValue = try container.decodeIfPresent(String.self, forKey: .selectedThemeRawValue) ?? "system"

        return EditorConfiguration(
            selectedThemeRawValue: decodedThemeRawValue,
            showLineNumbers: try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true,
            wordWrap: try container.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? false,
            minimapVisible: try container.decodeIfPresent(Bool.self, forKey: .minimapVisible) ?? false,
            showHiddenFilesInFileTree: try container.decodeIfPresent(Bool.self, forKey: .showHiddenFilesInFileTree) ?? false
        )
    }

    private static func decodeLegacyFileState(from container: KeyedDecodingContainer<CodingKeys>) throws -> FileState {
        FileState(
            lastOpenFileRelativePath: try container.decodeIfPresent(String.self, forKey: .lastOpenFileRelativePath),
            openTabRelativePaths: try container.decodeIfPresent([String].self, forKey: .openTabRelativePaths) ?? [],
            activeTabRelativePath: try container.decodeIfPresent(String.self, forKey: .activeTabRelativePath)
        )
    }

    private static func decodeLegacySplitEditorState(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> SplitEditorState {
        SplitEditorState(
            isSplitEditor: try container.decodeIfPresent(Bool.self, forKey: .isSplitEditor) ?? false,
            splitAxisRawValue: try container.decodeIfPresent(String.self, forKey: .splitAxisRawValue) ?? "vertical",
            focusedEditorPaneRawValue: try container.decodeIfPresent(String.self, forKey: .focusedEditorPaneRawValue) ?? "primary",
            primaryOpenTabRelativePaths: try container.decodeIfPresent([String].self, forKey: .primaryOpenTabRelativePaths) ?? [],
            primaryActiveTabRelativePath: try container.decodeIfPresent(String.self, forKey: .primaryActiveTabRelativePath),
            secondaryOpenTabRelativePaths: try container.decodeIfPresent([String].self, forKey: .secondaryOpenTabRelativePaths) ?? [],
            secondaryActiveTabRelativePath: try container.decodeIfPresent(String.self, forKey: .secondaryActiveTabRelativePath)
        )
    }

    private static func decodeLegacyFileTreeState(from container: KeyedDecodingContainer<CodingKeys>) throws -> FileTreeState {
        FileTreeState(
            fileTreeExpandedRelativePaths: try container.decodeIfPresent([String].self, forKey: .fileTreeExpandedRelativePaths) ?? [],
            languageOverridesByRelativePath: try container.decodeIfPresent([String: String].self, forKey: .languageOverridesByRelativePath) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(uiConfiguration, forKey: .uiConfiguration)
        try container.encode(editor, forKey: .editor)
        try container.encode(fileState, forKey: .fileState)
        try container.encode(splitEditor, forKey: .splitEditor)
        try container.encode(fileTree, forKey: .fileTree)
        try container.encode(aiModeRawValue, forKey: .aiModeRawValue)
    }
}
