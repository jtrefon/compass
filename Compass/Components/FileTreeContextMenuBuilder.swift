import AppKit

@MainActor
final class FileTreeContextMenuBuilder: NSObject {
    private let callbacks: FileTreeCallbacks
    private let dialogCoordinator: FileTreeDialogCoordinator
    private let trackedState: FileTreeTrackedState

    init(callbacks: FileTreeCallbacks,
         dialogCoordinator: FileTreeDialogCoordinator,
         trackedState: FileTreeTrackedState) {
        self.callbacks = callbacks
        self.dialogCoordinator = dialogCoordinator
        self.trackedState = trackedState
    }

    func updateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let item = trackedState.clickedItem else { return }
        let url = item.url

        addFileActionItems(menu, url: url)
        menu.addItem(NSMenuItem.separator())
        addRevealItem(menu, url: url)
        menu.addItem(NSMenuItem.separator())
        addCreateItems(menu)
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        callbacks.onOpenFile(url)
    }

    @objc func delete(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        callbacks.onDeleteItem(url)
    }

    @objc func rename(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let initialName = url.lastPathComponent
        guard let newName = dialogCoordinator.promptForRename(initialName: initialName) else { return }
        callbacks.onRenameItem(url, newName)
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        callbacks.onRevealInFinder(url)
    }

    @objc func newFile(_ sender: NSMenuItem) {
        guard let directory = trackedState.directoryForCreate() else { return }
        guard let name = dialogCoordinator.promptForNewItem(
            title: NSLocalizedString("file_tree.create_file.title", comment: ""),
            informativeText: NSLocalizedString("file_tree.create_file.info", comment: "")
        ) else { return }
        callbacks.onCreateFile(directory, name)
    }

    @objc func newFolder(_ sender: NSMenuItem) {
        guard let directory = trackedState.directoryForCreate() else { return }
        guard let name = dialogCoordinator.promptForNewItem(
            title: NSLocalizedString("file_tree.create_folder.title", comment: ""),
            informativeText: NSLocalizedString("file_tree.create_folder.info", comment: "")
        ) else { return }
        callbacks.onCreateFolder(directory, name)
    }

    // MARK: - Private

    private func addFileActionItems(_ menu: NSMenu, url: NSURL) {
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.open", comment: ""),
            action: #selector(open(_:)),
            representedObject: url
        ))
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.rename", comment: ""),
            action: #selector(rename(_:)),
            representedObject: url
        ))
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.delete", comment: ""),
            action: #selector(delete(_:)),
            representedObject: url
        ))
    }

    private func addRevealItem(_ menu: NSMenu, url: NSURL) {
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.show_in_finder", comment: ""),
            action: #selector(revealInFinder(_:)),
            representedObject: url
        ))
    }

    private func addCreateItems(_ menu: NSMenu) {
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.new_file", comment: ""),
            action: #selector(newFile(_:))
        ))
        menu.addItem(makeMenuItem(
            title: NSLocalizedString("file_tree.context.new_folder", comment: ""),
            action: #selector(newFolder(_:))
        ))
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }
}
