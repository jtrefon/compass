import SwiftUI
import AppKit

@MainActor
final class ModernFileTreeCoordinator: NSObject, NSOutlineViewDelegate, NSMenuDelegate {
    let dataSource = FileTreeDataSource()
    private let cellProvider: FileTreeCellProvider
    private let trackedState: FileTreeTrackedState

    // Specialized coordinators
    private let dialogCoordinator = FileTreeDialogCoordinator()
    private let contextMenuBuilder: FileTreeContextMenuBuilder
    private var searchEngine: FileTreeSearchEngine?
    private var appearanceCoordinator: FileTreeAppearanceCoordinator!

    typealias Configuration = ModernFileTreeCoordinatorConfiguration

    private let configuration: Configuration
    private weak var outlineView: NSOutlineView?
    private var state = FileTreeCoordinatorState()

    init(configuration: Configuration) {
        self.configuration = configuration
        self.cellProvider = FileTreeCellProvider(dataSource: dataSource)
        self.trackedState = FileTreeTrackedState(
            dataSource: dataSource,
            expandedRelativePaths: configuration.expandedRelativePaths,
            selectedRelativePath: configuration.selectedRelativePath
        )
        self.contextMenuBuilder = FileTreeContextMenuBuilder(
            callbacks: FileTreeCallbacks(
                onOpenFile: configuration.onOpenFile,
                onCreateFile: configuration.onCreateFile,
                onCreateFolder: configuration.onCreateFolder,
                onDeleteItem: configuration.onDeleteItem,
                onRenameItem: configuration.onRenameItem,
                onRevealInFinder: configuration.onRevealInFinder
            ),
            dialogCoordinator: dialogCoordinator,
            trackedState: trackedState
        )
        super.init()
    }

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        trackedState.outlineView = outlineView
        trackedState.rootURLProvider = { [weak self] in self?.state.rootURL }

        // Update appearance coordinator with the outline view
        appearanceCoordinator = FileTreeAppearanceCoordinator(outlineView: outlineView)

        outlineView.dataSource = dataSource
        outlineView.delegate = self

        // Wire search engine
        let engine = FileTreeSearchEngine(dataSource: dataSource, appearanceCoordinator: appearanceCoordinator)
        engine.outlineView = outlineView
        engine.rootURLProvider = { [weak self] in self?.state.rootURL }
        engine.onNeedsStructuralRefresh = { [weak self] in self?.applyStructuralRefresh() }
        searchEngine = engine

        // Set up contextual menu with delegate
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        outlineView.target = self
        outlineView.doubleAction = #selector(onDoubleClick)

        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        // Apply initial appearance
        appearanceCoordinator.applyAppearanceToVisibleRows()
    }

    func updateSearchQuery(_ query: String) {
        searchEngine?.updateQuery(query)
    }

    func updateShowHiddenFiles(_ show: Bool) {
        guard state.showHiddenFiles != show else { return }
        state.showHiddenFiles = show
        dataSource.setShowHiddenFiles(show)
        applyStructuralRefresh()
    }

    func updateRootURL(_ url: URL) {
        let rootPath = url.standardizedFileURL.path
        guard state.rootPath != rootPath else { return }
        state.rootPath = rootPath
        state.rootURL = url.standardizedFileURL
        dataSource.setRootURL(url)
        applyStructuralRefresh()
    }

    func updateFont(fontSize: Double, fontFamily: String) {
        state.fontSize = fontSize
        state.fontFamily = fontFamily
        applyAppearanceToVisibleRows()
    }

    func refreshTree(token: Int) {
        guard state.refreshToken != token else { return }
        state.refreshToken = token
        applyStructuralRefresh()
    }

    private func applyStructuralRefresh() {
        let savedSelectedPath = configuration.selectedRelativePath.wrappedValue
        dataSource.resetCaches()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            self.outlineView?.reloadData()
            self.trackedState.restoreExpandedState()
            self.trackedState.restoreSelection(savedSelectedPath)
            self.applyAppearanceToVisibleRows()
        }
    }

    private func applyAppearanceToVisibleRows() {
        guard let outlineView else { return }
        appearanceCoordinator.applyAppearanceToVisibleRows()
    }

    @objc func onDoubleClick(_ _: Any?) {
        guard let item = trackedState.clickedItem else { return }
        performOpen(for: item)
    }

    private func performOpen(for item: FileTreeItem) {
        configuration.onOpenFile(item.url as URL)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineViewItemDidExpand(_ notification: Notification) {
        trackedState.itemDidExpand(notification)
        applyAppearanceToVisibleRows()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        trackedState.itemDidCollapse(notification)
        applyAppearanceToVisibleRows()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        trackedState.selectionDidChange(notification)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let ftItem = item as? FileTreeItem else { return nil }
        return cellProvider.cell(for: ftItem, outlineView: outlineView,
                                fontSize: state.fontSize, fontFamily: state.fontFamily)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        contextMenuBuilder.updateMenu(menu)
    }
}
