import Foundation

public struct ProjectSession: Codable, Sendable {
    public typealias WindowFrame = ProjectSessionWindowFrame

    public var uiConfiguration: UIConfiguration
    public var editor: EditorConfiguration
    public var fileState: FileState
    public var splitEditor: SplitEditorState
    public var fileTree: FileTreeState
    public var aiModeRawValue: String

    public init(
        uiConfiguration: UIConfiguration,
        editor: EditorConfiguration,
        fileState: FileState,
        splitEditor: SplitEditorState,
        fileTree: FileTreeState,
        aiModeRawValue: String = "Chat"
    ) {
        self.uiConfiguration = uiConfiguration
        self.editor = editor
        self.fileState = fileState
        self.splitEditor = splitEditor
        self.fileTree = fileTree
        self.aiModeRawValue = aiModeRawValue
    }

    public static func `default`() -> ProjectSession {
        ProjectSession(
            uiConfiguration: UIConfiguration(windowFrame: nil),
            editor: EditorConfiguration(),
            fileState: FileState(),
            splitEditor: SplitEditorState(),
            fileTree: FileTreeState()
        )
    }

    public static func with(windowFrame: WindowFrame?) -> ProjectSessionBuilder {
        ProjectSessionBuilder().uiConfiguration(UIConfiguration(windowFrame: windowFrame))
    }
}
