import Foundation
import UniformTypeIdentifiers

extension EditorPaneStateManager {
    func loadFile(from url: URL) {
        guard validateFilePath(url.path) else {
            fileEditorService.handleError(AppError.invalidFilePath("Invalid file path: \(url.path)"))
            return
        }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            return
        }

        openTab(for: url)
    }

    func saveFile() {
        guard selectedFile != nil else {
            Task { @MainActor in
                await self.saveFileAs()
            }
            return
        }
        syncServiceState()
        fileEditorService.saveFile()
        isDirty = false
        persistActiveEditorStateToTab()
        if let activeID = activeTabID {
            if let idx = tabs.firstIndex(where: { $0.id == activeID }) {
                tabs[idx].isDirty = false
            }
        }
    }

    func saveFileAs() async {
        syncServiceState()
        let defaultName: String
        if let selectedFile {
            defaultName = URL(fileURLWithPath: selectedFile).lastPathComponent
        } else {
            defaultName = "Untitled.swift"
        }
        guard let url = await fileDialogService.saveFile(
            defaultFileName: defaultName,
            allowedContentTypes: [.swiftSource, .plainText]
        ) else {
            return
        }
        fileEditorService.saveFileAs(to: url)
        selectedFile = fileEditorService.selectedFile
        editorLanguage = fileEditorService.editorLanguage
        isDirty = false
    }

    func newFile() {
        tabs.removeAll()
        activeTabID = nil
        selectedRange = nil
        fileEditorService.newFile()
        selectedFile = nil
        editorContent = ""
        isDirty = false
        editorLanguage = "swift"
    }

    func updateEditorContent(_ newContent: String) {
        editingStateManager.updateEditorContent(
            EditingStateManager.UpdateEditorContentRequest(
                newContent: newContent,
                selectedFile: selectedFile,
                currentLanguage: editorLanguage,
                applyContent: { [weak self] in self?.editorContent = $0 },
                applyLanguage: { [weak self] in self?.editorLanguage = $0 },
                updateServiceContent: { [weak self] in self?.fileEditorService.editorContent = $0 }
            )
        )
    }

    func setEditorLanguage(_ language: String) {
        editingStateManager.setEditorLanguage(
            language: language,
            applyLanguage: { [weak self] in self?.editorLanguage = $0 },
            updateServiceLanguage: { [weak self] in self?.fileEditorService.editorLanguage = $0 }
        )
    }

    var canSave: Bool {
        isDirty && selectedFile != nil
    }

    var displayName: String {
        if let selectedFile {
            return URL(fileURLWithPath: selectedFile).lastPathComponent
        }
        return "Untitled"
    }

    func syncServiceState() {
        fileEditorService.selectedFile = selectedFile
        fileEditorService.editorContent = editorContent
        fileEditorService.editorLanguage = editorLanguage
    }

    func validateFilePath(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if path.contains("..") || path.contains("/../") {
            return false
        }

        let invalidChars = CharacterSet(charactersIn: "<>:\"?*\n\r")
        guard path.rangeOfCharacter(from: invalidChars) == nil else {
            return false
        }

        if path.count > AppConstantsFileSystem.maxPathLength {
            return false
        }

        return true
    }

    func openTab(for url: URL) {
        let path = url.path

        if let existingIdx = tabs.firstIndex(where: { $0.filePath == path }) {
            activateTab(id: tabs[existingIdx].id)
            return
        }

        persistActiveEditorStateToTab()

        isLoadingFile = true
        defer { isLoadingFile = false }

        fileEditorService.loadFile(from: url)

        let selectedPath = fileEditorService.selectedFile
        let content = fileEditorService.editorContent
        let language = fileEditorService.editorLanguage

        guard let selectedPath else { return }

        let newTab = EditorTab(filePath: selectedPath, language: language, content: content, isDirty: false)
        tabs.append(newTab)
        activeTabID = newTab.id

        selectedFile = selectedPath
        editorContent = content
        editorLanguage = language
        isDirty = false
        selectedRange = nil
    }
}
