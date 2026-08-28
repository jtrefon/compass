//
//  FileEditorService.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import Foundation
import SwiftUI

/// Manages file editing operations and state
@MainActor
class FileEditorService: ObservableObject, FileEditorServiceProtocol {
    @Published var selectedFile: String?
    @Published var editorContent = "" {
        didSet {
            if !isLoadingFile {
                isDirty = true
            }
        }
    }
    @Published var editorLanguage = "swift"
    @Published var isDirty = false

    private var isLoadingFile = false
    private let errorManager: any ErrorManagerProtocol
    private let fileSystemService: FileSystemService
    private let eventBus: any EventBusProtocol

    init(errorManager: any ErrorManagerProtocol, fileSystemService: FileSystemService, eventBus: any EventBusProtocol) {
        self.errorManager = errorManager
        self.fileSystemService = fileSystemService
        self.eventBus = eventBus
    }

    /// Handle error through the service's error manager
    func handleError(_ error: AppError) {
        errorManager.handle(error)
    }

    /// Load file content into editor
    func loadFile(from url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            return // Directory loading handled by WorkspaceService
        }

        isLoadingFile = true
        defer { isLoadingFile = false }

        switch fileSystemService.readFileResult(at: url) {
        case .success(let content):
            self.selectedFile = url.path
            self.editorContent = content
            self.editorLanguage = DefaultEditorLanguageDetector().languageForFileExtension(url.pathExtension)
            self.isDirty = false
            eventBus.publish(FileOpenedEvent(url: url, languageIdentifier: editorLanguage, content: content))
        case .failure(let error):
            errorManager.handle(error)
        }
    }

    /// Save current content to selected file
    func saveFile() {
        guard let filePath = selectedFile else { return }

        switch fileSystemService.writeFileResult(content: editorContent, toPath: filePath) {
        case .success:
            isDirty = false
            eventBus.publish(FileModifiedEvent(url: URL(fileURLWithPath: filePath)))
        case .failure(let error):
            errorManager.handle(error)
        }
    }

    /// Save file to new location
    func saveFileAs(to url: URL) {
        let oldPath = selectedFile

        switch fileSystemService.writeFileResult(content: editorContent, to: url) {
        case .success:
            selectedFile = url.path
            editorLanguage = DefaultEditorLanguageDetector().languageForFileExtension(url.pathExtension)
            isDirty = false
            if let oldPath, oldPath != url.path {
                eventBus.publish(FileRenamedEvent(oldUrl: URL(fileURLWithPath: oldPath), newUrl: url))
            } else {
                eventBus.publish(FileCreatedEvent(url: url))
            }
            eventBus.publish(FileModifiedEvent(url: url))
        case .failure(let error):
            errorManager.handle(error)
        }
    }

    /// Create new empty file
    func newFile() {
        selectedFile = nil
        editorContent = ""
        isDirty = false
    }

    /// Check if file can be saved
    var canSave: Bool {
        return isDirty && selectedFile != nil
    }

    /// Get current file name for display
    var displayName: String {
        if let selectedFile {
            return URL(fileURLWithPath: selectedFile).lastPathComponent
        }
        return "Untitled"
    }
}
