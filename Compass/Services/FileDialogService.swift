import AppKit
import UniformTypeIdentifiers

/// Handles user-facing file dialogs.
@MainActor
final class FileDialogService: FileDialogServiceProtocol {
    private let windowProvider: WindowProviding

    init(windowProvider: WindowProviding) {
        self.windowProvider = windowProvider
    }

    func openFileOrFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.swiftSource, .plainText, .sourceCode, .folder]

        return await runOpenPanel(panel)
    }

    func openFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"

        return await runOpenPanel(panel)
    }

    func saveFile(defaultFileName: String, allowedContentTypes: [UTType]) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.nameFieldStringValue = defaultFileName

        return await runSavePanel(panel)
    }

    func promptForNewProjectFolder(defaultName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Create"
        panel.title = "New Project"
        panel.message = "Choose where to create the project folder, then enter a project name."

        guard let url = await runSavePanel(panel) else { return nil }
        return url
    }

    private func runOpenPanel(_ panel: NSOpenPanel) async -> URL? {
        await withCheckedContinuation { continuation in
            if let window = windowProvider.window ?? NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                let response = panel.runModal()
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private func runSavePanel(_ panel: NSSavePanel) async -> URL? {
        await withCheckedContinuation { continuation in
            if let window = windowProvider.window ?? NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                let response = panel.runModal()
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
