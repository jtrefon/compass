import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class ProjectSessionCoordinator {
    private let projectSessionStore = ProjectSessionStore()

    private weak var window: NSWindow?
    private var saveSessionTask: Task<Void, Never>?
    private var isRestoringSession: Bool = false
    private var hasLoadedInitialSession: Bool = false

    private let workspace: WorkspaceStateManager
    private let ui: UIStateManager
    private let fileEditor: FileEditorStateManager
    private let conversationManager: any ConversationManagerProtocol

    private let getFileTreeExpandedRelativePaths: () -> Set<String>
    private let setFileTreeExpandedRelativePaths: (Set<String>) -> Void

    private let getShowHiddenFilesInFileTree: () -> Bool
    private let setShowHiddenFilesInFileTree: (Bool) -> Void

    private let getLanguageOverridesByRelativePath: () -> [String: String]
    private let setLanguageOverridesByRelativePath: ([String: String]) -> Void

    private let relativePathForURL: (URL) -> String?
    private let loadFileFromURL: (URL) -> Void

    private var cancellables = Set<AnyCancellable>()

    init(
        workspace: WorkspaceStateManager,
        ui: UIStateManager,
        fileEditor: FileEditorStateManager,
        conversationManager: any ConversationManagerProtocol,
        getFileTreeExpandedRelativePaths: @escaping () -> Set<String>,
        setFileTreeExpandedRelativePaths: @escaping (Set<String>) -> Void,
        getShowHiddenFilesInFileTree: @escaping () -> Bool,
        setShowHiddenFilesInFileTree: @escaping (Bool) -> Void,
        getLanguageOverridesByRelativePath: @escaping () -> [String: String],
        setLanguageOverridesByRelativePath: @escaping ([String: String]) -> Void,
        relativePathForURL: @escaping (URL) -> String?,
        loadFileFromURL: @escaping (URL) -> Void
    ) {
        self.workspace = workspace
        self.ui = ui
        self.fileEditor = fileEditor
        self.conversationManager = conversationManager
        self.getFileTreeExpandedRelativePaths = getFileTreeExpandedRelativePaths
        self.setFileTreeExpandedRelativePaths = setFileTreeExpandedRelativePaths
        self.getShowHiddenFilesInFileTree = getShowHiddenFilesInFileTree
        self.setShowHiddenFilesInFileTree = setShowHiddenFilesInFileTree

        self.getLanguageOverridesByRelativePath = getLanguageOverridesByRelativePath
        self.setLanguageOverridesByRelativePath = setLanguageOverridesByRelativePath
        self.relativePathForURL = relativePathForURL
        self.loadFileFromURL = loadFileFromURL
    }

    func attachWindow(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleSaveProjectSession()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleSaveProjectSession()
            }
            .store(in: &cancellables)
    }

    func loadProjectSessionIfAvailable() {
        guard let root = workspace.currentDirectory else { return }
        Task { [weak self] in
            await self?.loadProjectSession(for: root)
        }
    }

    func loadProjectSession(for projectRoot: URL) async {
        await loadProjectSessionImpl(for: projectRoot)
    }

    func scheduleSaveProjectSession() {
        guard !isRestoringSession else { return }
        guard hasLoadedInitialSession else { return }
        saveSessionTask?.cancel()
        saveSessionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { [weak self] in
                self?.saveProjectSessionNow()
            }
        }
    }

    func persistProjectSessionNow() {
        guard !isRestoringSession else { return }
        guard hasLoadedInitialSession else { return }
        saveSessionTask?.cancel()
        saveProjectSessionNow()
    }

    private func loadExistingNonDirectoryFileIfPresent(_ url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]))?.isDirectory ?? false
        if FileManager.default.fileExists(atPath: url.path), !isDir {
            loadFileFromURL(url)
        }
    }

    private func restoreTabs(
        pane: FileEditorStateManager.PaneID,
        projectRoot: URL,
        openTabRelativePaths: [String],
        activeTabRelativePath: String?
    ) {
        guard !openTabRelativePaths.isEmpty else { return }
        fileEditor.focus(pane)
        for rel in openTabRelativePaths {
            loadExistingNonDirectoryFileIfPresent(projectRoot.appendingPathComponent(rel))
        }
        if let activeRel = activeTabRelativePath {
            fileEditor.activateTab(filePath: projectRoot.appendingPathComponent(activeRel).path)
        }
    }

    private func relativePathForActiveTab(
        activeTabID: UUID?,
        tabs: [EditorPaneStateManager.EditorTab]
    ) -> String? {
        guard let activeTabID,
              let activeTab = tabs.first(where: { $0.id == activeTabID }) else {
            return nil
        }
        return relativePathForURL(URL(fileURLWithPath: activeTab.filePath))
    }

    private func loadProjectSessionImpl(for projectRoot: URL) async {
        isRestoringSession = true
        hasLoadedInitialSession = false
        var shouldBootstrapSave = false
        defer {
            isRestoringSession = false
            hasLoadedInitialSession = true
            if shouldBootstrapSave {
                scheduleSaveProjectSession()
            }
        }

        await projectSessionStore.setProjectRoot(projectRoot)

        guard let session = try? await projectSessionStore.load() else {
            shouldBootstrapSave = true
            return
        }

        let visibleFrame = (window?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let uiConfig = session.uiConfiguration
        let editorConfig = session.editor
        let fileState = session.fileState
        let splitEditorState = session.splitEditor
        let fileTreeState = session.fileTree

        var normalizedWindowRect = uiConfig.windowFrame?.rect

        if let frame = uiConfig.windowFrame?.rect {
            let targetFrame = UILayoutNormalizer.normalizeWindowFrame(
                frame,
                screenVisibleFrame: visibleFrame
            )
            normalizedWindowRect = targetFrame
            if let window {
                window.setFrame(targetFrame, display: true)
            }
        }

        ui.isSidebarVisible = uiConfig.isSidebarVisible
        ui.isTerminalVisible = uiConfig.isTerminalVisible
        ui.isAIChatVisible = uiConfig.isAIChatVisible
        ui.isCodePanelVisible = uiConfig.isCodePanelVisible
        let referenceFrame = window?.frame
            ?? normalizedWindowRect
            ?? NSRect(x: 0, y: 0, width: visibleFrame.width, height: visibleFrame.height)
        let normalizedTerminalHeight = UILayoutNormalizer.normalizeTerminalHeight(
            uiConfig.terminalHeight,
            windowHeight: referenceFrame.height
        )
        ui.sidebarWidth = uiConfig.sidebarWidth
        ui.terminalHeight = normalizedTerminalHeight
        ui.chatPanelWidth = uiConfig.chatPanelWidth

        if let theme = AppTheme(rawValue: editorConfig.selectedThemeRawValue) {
            ui.selectedTheme = theme
        }
        ui.showLineNumbers = editorConfig.showLineNumbers
        ui.wordWrap = editorConfig.wordWrap
        ui.minimapVisible = editorConfig.minimapVisible

        setShowHiddenFilesInFileTree(editorConfig.showHiddenFilesInFileTree)

        setLanguageOverridesByRelativePath(fileTreeState.languageOverridesByRelativePath)

        if let mode = AIMode(rawValue: session.aiModeRawValue) {
            conversationManager.currentMode = mode
        }

        setFileTreeExpandedRelativePaths(Set(fileTreeState.fileTreeExpandedRelativePaths))

        fileEditor.newFile()

        let splitAxis = FileEditorStateManager.SplitAxis(rawValue: splitEditorState.splitAxisRawValue) ?? .vertical
        fileEditor.splitAxis = splitAxis
        fileEditor.isSplitEditor = splitEditorState.isSplitEditor
        let focused = FileEditorStateManager.PaneID(rawValue: splitEditorState.focusedEditorPaneRawValue) ?? .primary
        fileEditor.focusedPane = focused

        let primaryRelPaths = !splitEditorState.primaryOpenTabRelativePaths.isEmpty
            ? splitEditorState.primaryOpenTabRelativePaths
            : fileState.openTabRelativePaths
        let primaryActiveRel = splitEditorState.primaryActiveTabRelativePath ?? fileState.activeTabRelativePath

        restoreTabs(
            pane: .primary,
            projectRoot: projectRoot,
            openTabRelativePaths: primaryRelPaths,
            activeTabRelativePath: primaryActiveRel
        )

        if splitEditorState.isSplitEditor {
            restoreTabs(
                pane: .secondary,
                projectRoot: projectRoot,
                openTabRelativePaths: splitEditorState.secondaryOpenTabRelativePaths,
                activeTabRelativePath: splitEditorState.secondaryActiveTabRelativePath
            )
        }

        fileEditor.focus(focused)

        if primaryRelPaths.isEmpty, let rel = fileState.lastOpenFileRelativePath {
            loadExistingNonDirectoryFileIfPresent(projectRoot.appendingPathComponent(rel))
        }
    }

    private func saveProjectSessionNow() {
        guard !isRestoringSession else { return }
        guard let projectRoot = workspace.currentDirectory else { return }

        let windowFrame = window.map { ProjectSession.WindowFrame(rect: $0.frame) }
        let lastOpenRelative: String?
        let openTabRelatives: [String]
        let activeRelative: String?

        let focusedPaneState = fileEditor.focusedPaneState

        activeRelative = relativePathForActiveTab(
            activeTabID: focusedPaneState.activeTabID,
            tabs: focusedPaneState.tabs
        )

        openTabRelatives = focusedPaneState.tabs.compactMap {
            relativePathForURL(URL(fileURLWithPath: $0.filePath))
        }
        lastOpenRelative = activeRelative

        let primaryTabs = fileEditor.primaryPane.tabs.compactMap {
            relativePathForURL(URL(fileURLWithPath: $0.filePath))
        }
        let secondaryTabs = fileEditor.secondaryPane.tabs.compactMap {
            relativePathForURL(URL(fileURLWithPath: $0.filePath))
        }

        let primaryActive = relativePathForActiveTab(
            activeTabID: fileEditor.primaryPane.activeTabID,
            tabs: fileEditor.primaryPane.tabs
        )

        let secondaryActive = relativePathForActiveTab(
            activeTabID: fileEditor.secondaryPane.activeTabID,
            tabs: fileEditor.secondaryPane.tabs
        )

        let session = ProjectSession(
            uiConfiguration: UIConfiguration(
                windowFrame: windowFrame,
                isSidebarVisible: ui.isSidebarVisible,
                isTerminalVisible: ui.isTerminalVisible,
                isAIChatVisible: ui.isAIChatVisible,
                sidebarWidth: ui.sidebarWidth,
                terminalHeight: ui.terminalHeight,
                chatPanelWidth: ui.chatPanelWidth
            ),
            editor: EditorConfiguration(
                selectedThemeRawValue: ui.selectedTheme.rawValue,
                showLineNumbers: ui.showLineNumbers,
                wordWrap: ui.wordWrap,
                minimapVisible: ui.minimapVisible,
                showHiddenFilesInFileTree: getShowHiddenFilesInFileTree()
            ),
            fileState: FileState(
                lastOpenFileRelativePath: lastOpenRelative,
                openTabRelativePaths: openTabRelatives,
                activeTabRelativePath: activeRelative
            ),
            splitEditor: SplitEditorState(
                isSplitEditor: fileEditor.isSplitEditor,
                splitAxisRawValue: fileEditor.splitAxis.rawValue,
                focusedEditorPaneRawValue: fileEditor.focusedPane.rawValue,
                primaryOpenTabRelativePaths: primaryTabs,
                primaryActiveTabRelativePath: primaryActive,
                secondaryOpenTabRelativePaths: secondaryTabs,
                secondaryActiveTabRelativePath: secondaryActive
            ),
            fileTree: FileTreeState(
                fileTreeExpandedRelativePaths: Array(getFileTreeExpandedRelativePaths()).sorted(),
                languageOverridesByRelativePath: getLanguageOverridesByRelativePath()
            ),
            aiModeRawValue: conversationManager.currentMode.rawValue
        )

        Task {
            await projectSessionStore.setProjectRoot(projectRoot)
            try? await projectSessionStore.save(session)
        }
    }
}
