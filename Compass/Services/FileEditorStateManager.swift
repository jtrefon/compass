//
//  FileEditorStateManager.swift
//  Compass
//
//  Created by Jack Trefon on 20/12/2025.
//

import SwiftUI
import Combine

@MainActor
final class FileEditorStateManager: ObservableObject {
    enum PaneID: String, Codable, Sendable {
        case primary
        case secondary
    }

    enum SplitAxis: String, Codable, Sendable {
        case vertical
        case horizontal
    }

    @Published var isSplitEditor: Bool = false
    @Published var splitAxis: SplitAxis = .vertical
    @Published var focusedPane: PaneID = .primary

    let primaryPane: EditorPaneStateManager
    let secondaryPane: EditorPaneStateManager

    init(
        fileEditorService: any FileEditorServiceProtocol,
        fileDialogService: any FileDialogServiceProtocol,
        fileSystemService: FileSystemService
    ) {
        self.primaryPane = EditorPaneStateManager(
            fileEditorService: fileEditorService,
            fileDialogService: fileDialogService,
            fileSystemService: fileSystemService
        )
        self.secondaryPane = EditorPaneStateManager(
            fileEditorService: fileEditorService,
            fileDialogService: fileDialogService,
            fileSystemService: fileSystemService
        )

        primaryPane.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        secondaryPane.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    var focusedPaneState: EditorPaneStateManager {
        focusedPane == .primary ? primaryPane : secondaryPane
    }

    func focus(_ pane: PaneID) {
        focusedPane = pane
    }

    func toggleSplit(axis: SplitAxis) {
        if isSplitEditor, splitAxis == axis {
            isSplitEditor = false
            focusedPane = .primary
            return
        }

        splitAxis = axis
        isSplitEditor = true
        if focusedPane == .secondary {
            focusedPane = .secondary
        }
    }

    func closeSplit() {
        isSplitEditor = false
        focusedPane = .primary
    }

    func focusNextPane() {
        guard isSplitEditor else { return }
        focusedPane = (focusedPane == .primary) ? .secondary : .primary
    }

    func openInOtherPane(from url: URL) {
        if !isSplitEditor {
            isSplitEditor = true
        }
        let other: PaneID = (focusedPane == .primary) ? .secondary : .primary
        focusedPane = other
        focusedPaneState.loadFile(from: url)
    }

    func loadFile(from url: URL) {
        focusedPaneState.loadFile(from: url)
    }

    func activateTab(id: UUID) {
        focusedPaneState.activateTab(id: id)
    }

    func activateTab(filePath: String) {
        if primaryPane.tabs.contains(where: { $0.filePath == filePath }) {
            focusedPane = .primary
            primaryPane.activateTab(filePath: filePath)
            return
        }

        if secondaryPane.tabs.contains(where: { $0.filePath == filePath }) {
            focusedPane = .secondary
            secondaryPane.activateTab(filePath: filePath)
        }
    }

    func saveFile() {
        focusedPaneState.saveFile()
    }

    func saveFileAs() async {
        await focusedPaneState.saveFileAs()
    }

    func selectLine(_ line: Int) {
        focusedPaneState.selectLine(line)
    }

    func closeActiveTab() {
        focusedPaneState.closeActiveTab()
    }

    func activateNextTab() {
        focusedPaneState.activateNextTab()
    }

    func activatePreviousTab() {
        focusedPaneState.activatePreviousTab()
    }

    func newFile() {
        primaryPane.newFile()
        secondaryPane.newFile()
        closeSplit()
    }

    func closeAllTabs() {
        primaryPane.newFile()
        secondaryPane.newFile()
    }

    func closeTab(filePath: String) {
        if primaryPane.tabs.contains(where: { $0.filePath == filePath }) {
            primaryPane.closeTab(filePath: filePath)
        }
        if secondaryPane.tabs.contains(where: { $0.filePath == filePath }) {
            secondaryPane.closeTab(filePath: filePath)
        }
    }

    func renameTab(oldPath: String, newPath: String) {
        if primaryPane.tabs.contains(where: { $0.filePath == oldPath }) {
            primaryPane.renameTab(oldPath: oldPath, newPath: newPath)
        }
        if secondaryPane.tabs.contains(where: { $0.filePath == oldPath }) {
            secondaryPane.renameTab(oldPath: oldPath, newPath: newPath)
        }
    }

    func handleExternalFileChanges(paths: [String]) {
        for path in paths {
            primaryPane.reloadFileIfOpen(path: path)
            secondaryPane.reloadFileIfOpen(path: path)
        }
    }

    func tab(for filePath: String) -> EditorPaneStateManager.EditorTab? {
        findTabInPane(primaryPane, filePath: filePath) ?? findTabInPane(secondaryPane, filePath: filePath)
    }

    private func findTabInPane(_ pane: EditorPaneStateManager, filePath: String) -> EditorPaneStateManager.EditorTab? {
        pane.tabs.first(where: { $0.filePath == filePath })
    }

    func isFileOpenAndDirty(filePath: String) -> Bool {
        tab(for: filePath)?.isDirty ?? false
    }

    var tabs: [EditorPaneStateManager.EditorTab] {
        focusedPaneState.tabs
    }

    var activeTabID: UUID? {
        focusedPaneState.activeTabID
    }

    var selectedFile: String? {
        focusedPaneState.selectedFile
    }

    var editorContent: String {
        get { focusedPaneState.editorContent }
        set { focusedPaneState.updateEditorContent(newValue) }
    }

    var editorLanguage: String {
        get { focusedPaneState.editorLanguage }
        set { focusedPaneState.setEditorLanguage(newValue) }
    }

    var isDirty: Bool {
        focusedPaneState.isDirty
    }

    var canSave: Bool {
        focusedPaneState.canSave
    }

    var displayName: String {
        focusedPaneState.displayName
    }

    var selectedRange: NSRange? {
        get { focusedPaneState.selectedRange }
        set { focusedPaneState.selectedRange = newValue }
    }

    static func languageForFileExtension(_ fileExtension: String) -> String {
        DefaultEditorLanguageDetector().languageForFileExtension(fileExtension)
    }
}
