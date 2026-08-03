import Foundation

extension EditorPaneStateManager {
    struct EditorTab: Identifiable, Equatable {
        let id: UUID
        var filePath: String
        var language: String
        var content: String
        var isDirty: Bool
        var selectedRange: NSRange?

        init(filePath: String, language: String, content: String, isDirty: Bool, selectedRange: NSRange? = nil) {
            self.id = UUID()
            self.filePath = filePath
            self.language = language
            self.content = content
            self.isDirty = isDirty
            self.selectedRange = selectedRange
        }
    }

    func closeTab(filePath: String) {
        guard let idx = tabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        closeTab(id: tabs[idx].id)
    }

    func renameTab(oldPath: String, newPath: String) {
        guard let idx = tabs.firstIndex(where: { $0.filePath == oldPath }) else { return }
        tabs[idx].filePath = newPath

        if activeTabID == tabs[idx].id {
            selectedFile = newPath
            fileEditorService.selectedFile = newPath
        }
    }

    func activateTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        persistActiveEditorStateToTab()
        activeTabID = id

        let tab = tabs[idx]
        isLoadingFile = true
        defer { isLoadingFile = false }
        selectedFile = tab.filePath
        editorLanguage = tab.language
        editorContent = tab.content
        isDirty = tab.isDirty
        selectedRange = tab.selectedRange
    }

    func activateTab(filePath: String) {
        guard let idx = tabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        activateTab(id: tabs[idx].id)
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: idx)

        if activeTabID == removed.id {
            if let newActive = tabs.last {
                activateTab(id: newActive.id)
            } else {
                newFile()
            }
        }
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id: id)
    }

    func activateNextTab() {
        guard !tabs.isEmpty else { return }
        guard let activeTabID else { activateTab(id: tabs[0].id); return }
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { activateTab(id: tabs[0].id); return }
        activateTab(id: tabs[(idx + 1) % tabs.count].id)
    }

    func activatePreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let activeTabID else { activateTab(id: tabs[0].id); return }
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { activateTab(id: tabs[0].id); return }
        activateTab(id: tabs[(idx - 1 + tabs.count) % tabs.count].id)
    }

    func persistActiveEditorStateToTab() {
        guard let activeID = activeTabID else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        tabs[idx].content = editorContent
        tabs[idx].language = editorLanguage
        tabs[idx].isDirty = isDirty
        tabs[idx].selectedRange = selectedRange
    }
}
