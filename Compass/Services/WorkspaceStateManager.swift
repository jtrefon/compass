//
//  WorkspaceStateManager.swift
//  Compass
//
//  Created by Jack Trefon on 20/12/2025.
//

import SwiftUI
import Combine

/// Manages workspace state and operations
@MainActor
class WorkspaceStateManager: ObservableObject {
    @Published var currentDirectory: URL?
    @Published var openFiles: [String: URL] = [:]
    @Published var recentlyOpenedFiles: [URL] = []

    private let workspaceService: any WorkspaceServiceProtocol
    private let fileDialogService: any FileDialogServiceProtocol

    init(workspaceService: any WorkspaceServiceProtocol, fileDialogService: any FileDialogServiceProtocol) {
        self.workspaceService = workspaceService
        self.fileDialogService = fileDialogService
        self.currentDirectory = workspaceService.currentDirectory
    }

    // MARK: - Directory Operations

    private func saveCurrentDirectory(_ url: URL) {
        workspaceService.currentDirectory = url
        currentDirectory = url
    }

    /// Open file dialog for selecting files or directories
    /// - Parameter onFileSelected: Callback invoked when a file (not directory) is selected
    func openFileOrFolder(onFileSelected: ((URL) -> Void)? = nil) async {
        guard let url = await fileDialogService.openFileOrFolder() else { return }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            saveCurrentDirectory(url)
            // Explicitly trigger objectWillChange to ensure all observers are notified
            objectWillChange.send()
        } else {
            saveCurrentDirectory(url.deletingLastPathComponent())
            // Explicitly trigger objectWillChange to ensure all observers are notified
            objectWillChange.send()
            addToRecentlyOpened(url)
            onFileSelected?(url)
        }
    }

    /// Open folder dialog specifically for directories
    func openFolder() async {
        guard let url = await fileDialogService.openFolder() else { return }
        saveCurrentDirectory(url)
        // Explicitly trigger objectWillChange to ensure all observers are notified
        // This ensures SwiftUI views that observe this manager get updated
        objectWillChange.send()
        
        // Notify the app state to refresh the file tree for the new directory
        NotificationCenter.default.post(name: NSNotification.Name("WorkspaceDirectoryDidChange"), object: nil)
    }

    /// Navigate to parent directory
    func navigateToParent() {
        workspaceService.navigateToParent()
        currentDirectory = workspaceService.currentDirectory
        // Explicitly trigger objectWillChange to ensure all observers are notified
        objectWillChange.send()
        NotificationCenter.default.post(name: NSNotification.Name("WorkspaceDirectoryDidChange"), object: nil)
    }

    /// Navigate to subdirectory
    func navigateTo(subdirectory: String) {
        workspaceService.navigateTo(subdirectory: subdirectory)
        currentDirectory = workspaceService.currentDirectory
        // Explicitly trigger objectWillChange to ensure all observers are notified
        objectWillChange.send()
        NotificationCenter.default.post(name: NSNotification.Name("WorkspaceDirectoryDidChange"), object: nil)
    }

    // MARK: - File Management

    /// Create a new file in the current directory with validation
    func createFile(named name: String) async {
        guard validateFileName(name) else {
            workspaceService.handleError(.invalidFilePath("Invalid file name: \(name)"))
            return
        }

        guard let directory = currentDirectory else {
            workspaceService.handleError(.invalidFilePath("No current directory selected"))
            return
        }

        await workspaceService.createFile(named: name, in: directory)
    }

    /// Create a new folder in the current directory with validation
    func createFolder(named name: String) async {
        guard validateFileName(name) else {
            workspaceService.handleError(.invalidFilePath("Invalid folder name: \(name)"))
            return
        }

        guard let directory = currentDirectory else {
            workspaceService.handleError(.invalidFilePath("No current directory selected"))
            return
        }

        await workspaceService.createFolder(named: name, in: directory)
    }

    /// Create a new project directory at the specified path.
    /// The provided URL is expected to be the full folder path to create.
    func createProject(at projectURL: URL) {
        let name = projectURL.lastPathComponent
        guard validateFileName(name) else {
            workspaceService.handleError(.invalidFilePath("Invalid project name: \(name)"))
            return
        }

        if FileManager.default.fileExists(atPath: projectURL.path) {
            workspaceService.handleError(.invalidFilePath("Project directory already exists: \(name)"))
            return
        }

        do {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            workspaceService.currentDirectory = projectURL
            currentDirectory = projectURL
            // Explicitly trigger objectWillChange to ensure all observers are notified
            objectWillChange.send()
        } catch {
            workspaceService.handleError(
                .invalidFilePath("Failed to create project directory: \(error.localizedDescription)")
            )
        }
    }

    /// Check if path is valid and accessible
    func isValidPath(_ path: String) -> Bool {
        return workspaceService.isValidPath(path)
    }

    // MARK: - Recently Opened Files Management

    private func addToRecentlyOpened(_ url: URL) {
        // Remove if already exists
        recentlyOpenedFiles.removeAll { $0 == url }

        // Add to front
        recentlyOpenedFiles.insert(url, at: 0)

        // Limit to maxRecentFiles
        if recentlyOpenedFiles.count > AppConstantsFileSystem.maxRecentFiles {
            recentlyOpenedFiles = Array(recentlyOpenedFiles.prefix(AppConstantsFileSystem.maxRecentFiles))
        }
    }

    /// Remove file from recently opened list
    func removeFromRecentlyOpened(_ url: URL) {
        recentlyOpenedFiles.removeAll { $0 == url }
    }

    /// Clear recently opened files
    func clearRecentlyOpened() {
        recentlyOpenedFiles.removeAll()
    }

    // MARK: - Open Files Management

    /// Add file to open files list
    func addOpenFile(_ url: URL) {
        openFiles[url.lastPathComponent] = url
    }

    /// Remove file from open files list
    func removeOpenFile(_ url: URL) {
        openFiles.removeValue(forKey: url.lastPathComponent)
    }

    /// Check if file is currently open
    func isFileOpen(_ url: URL) -> Bool {
        return openFiles[url.lastPathComponent] != nil
    }

    /// Get all open files
    func getOpenFiles() -> [URL] {
        return Array(openFiles.values)
    }

    // MARK: - Workspace Information

    /// Get workspace display name
    var workspaceDisplayName: String {
        return currentDirectory?.lastPathComponent ?? "No Workspace"
    }

    /// Check if workspace is empty (no current directory)
    var isWorkspaceEmpty: Bool {
        return currentDirectory == nil
    }

    /// Validate file/folder name for security and correctness
    private func validateFileName(_ name: String) -> Bool {
        guard !name.isEmpty && name.count <= 255 else { return false }
        guard !containsPathTraversalOrSlash(name) else { return false }
        guard !hasLeadingOrTrailingSpecialChars(name) else { return false }
        guard !containsInvalidChars(name) else { return false }
        guard !isReservedName(name) else { return false }
        return true
    }

    private func containsPathTraversalOrSlash(_ name: String) -> Bool {
        name.contains("..") || name.contains("/")
    }

    private func hasLeadingOrTrailingSpecialChars(_ name: String) -> Bool {
        name.first == "." || name.last == "." || name.first == " " || name.last == " "
    }

    private func containsInvalidChars(_ name: String) -> Bool {
        let invalidChars = CharacterSet(charactersIn: ":<>|?*\"\0")
        return name.rangeOfCharacter(from: invalidChars) != nil
    }

    private func isReservedName(_ name: String) -> Bool {
        let reservedNames = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
        return reservedNames.contains(name.uppercased())
    }
}
