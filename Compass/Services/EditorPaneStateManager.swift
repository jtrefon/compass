import SwiftUI
import Combine

/// Manages file editor state and operations
@MainActor
final class EditorPaneStateManager: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var activeTabID: UUID?
    @Published var selectedFile: String?
    @Published var editorContent: String = ""
    @Published var editorLanguage: String = "swift"
    @Published var isDirty: Bool = false
    @Published var selectedRange: NSRange?
    @Published var isLoadingFile: Bool = false
    @Published var markdownViewMode: Bool {
        didSet {
            UserDefaults.standard.set(markdownViewMode, forKey: AppConstants.Storage.markdownViewModeKey)
        }
    }

    let fileEditorService: any FileEditorServiceProtocol
    let fileDialogService: any FileDialogServiceProtocol
    let fileSystemService: FileSystemService

    let languageDetector: EditorLanguageDetecting
    let editingStateManager: EditingStateManager

    init(
        fileEditorService: any FileEditorServiceProtocol,
        fileDialogService: any FileDialogServiceProtocol,
        fileSystemService: FileSystemService
    ) {
        self.fileEditorService = fileEditorService
        self.fileDialogService = fileDialogService
        self.fileSystemService = fileSystemService

        let languageDetector = DefaultEditorLanguageDetector()
        self.languageDetector = languageDetector
        self.editingStateManager = EditingStateManager(languageDetector: languageDetector)

        if UserDefaults.standard.object(forKey: AppConstants.Storage.markdownViewModeKey) != nil {
            self.markdownViewMode = UserDefaults.standard.bool(forKey: AppConstants.Storage.markdownViewModeKey)
        } else {
            self.markdownViewMode = true
        }
    }

    func toggleMarkdownViewMode() {
        markdownViewMode.toggle()
    }

    func reloadFileIfOpen(path: String) {
        guard tabs.contains(where: { $0.filePath == path }) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            closeTab(filePath: path)
        } else {
            reloadFileFromDisk(for: path)
        }
    }

    private func reloadFileFromDisk(for path: String) {
        guard let idx = tabs.firstIndex(where: { $0.filePath == path }) else { return }
        guard !tabs[idx].isDirty else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        let url = URL(fileURLWithPath: path)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard !isDirectory else { return }

        guard let newContent = readFileContent(from: url) else { return }
        guard newContent != tabs[idx].content else { return }

        tabs[idx].content = newContent
        tabs[idx].isDirty = false

        if activeTabID == tabs[idx].id {
            isLoadingFile = true
            defer { isLoadingFile = false }
            editorContent = newContent
            isDirty = false
        }
    }

    private func readFileContent(from url: URL) -> String? {
        switch fileSystemService.readFileResult(at: url) {
        case .success(let content): return content
        case .failure: return nil
        }
    }
}
