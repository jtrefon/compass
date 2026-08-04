import Foundation

public class ProjectSessionBuilder {
    private var uiConfiguration: UIConfiguration = UIConfiguration(windowFrame: nil)
    private var editor: EditorConfiguration = EditorConfiguration()
    private var fileState: FileState = FileState()
    private var splitEditor: SplitEditorState = SplitEditorState()
    private var fileTree: FileTreeState = FileTreeState()
    private var aiModeRawValue: String = "Chat"

    public init() {}

    @available(*, deprecated, message: "Use uiConfiguration(_:) instead")
    public func ui(_ uiConfiguration: UIConfiguration) -> ProjectSessionBuilder {
        self.uiConfiguration = uiConfiguration
        return self
    }

    public func uiConfiguration(_ uiConfiguration: UIConfiguration) -> ProjectSessionBuilder {
        self.uiConfiguration = uiConfiguration
        return self
    }

    public func editor(_ editor: EditorConfiguration) -> ProjectSessionBuilder {
        self.editor = editor
        return self
    }

    public func fileState(_ fileState: FileState) -> ProjectSessionBuilder {
        self.fileState = fileState
        return self
    }

    public func splitEditor(_ splitEditor: SplitEditorState) -> ProjectSessionBuilder {
        self.splitEditor = splitEditor
        return self
    }

    public func fileTree(_ fileTree: FileTreeState) -> ProjectSessionBuilder {
        self.fileTree = fileTree
        return self
    }

    public func aiMode(_ aiModeRawValue: String) -> ProjectSessionBuilder {
        self.aiModeRawValue = aiModeRawValue
        return self
    }

    public func build() -> ProjectSession {
        ProjectSession(
            uiConfiguration: uiConfiguration,
            editor: editor,
            fileState: fileState,
            splitEditor: splitEditor,
            fileTree: fileTree,
            aiModeRawValue: aiModeRawValue
        )
    }
}
