import AppKit
import SwiftUI

@MainActor
final class FileTreeTrackedState {
    private let dataSource: FileTreeDataSource
    private let expandedRelativePaths: Binding<Set<String>>
    private let selectedRelativePath: Binding<String?>
    weak var outlineView: NSOutlineView?
    var rootURLProvider: (() -> URL?)?

    init(dataSource: FileTreeDataSource,
         expandedRelativePaths: Binding<Set<String>>,
         selectedRelativePath: Binding<String?>) {
        self.dataSource = dataSource
        self.expandedRelativePaths = expandedRelativePaths
        self.selectedRelativePath = selectedRelativePath
    }

    var selectedItem: FileTreeItem? {
        guard let outlineView else { return nil }
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileTreeItem
    }

    var clickedItem: FileTreeItem? {
        guard let outlineView else { return nil }
        let row = outlineView.clickedRow
        if row >= 0 { return outlineView.item(atRow: row) as? FileTreeItem }
        return selectedItem
    }

    func directoryForCreate() -> URL? {
        if let item = clickedItem {
            if dataSource.isDirectory(item.url) {
                return (item.url as URL).standardizedFileURL
            }
            return (item.url as URL).deletingLastPathComponent().standardizedFileURL
        }
        return rootURLProvider?()?.standardizedFileURL
    }

    func restoreExpandedState() {
        guard !dataSource.isSearching, let outlineView else { return }

        let targets = expandedRelativePaths.wrappedValue
            .sorted { left, right in
                let leftDepth = left.split(separator: "/").count
                let rightDepth = right.split(separator: "/").count
                if leftDepth != rightDepth { return leftDepth < rightDepth }
                return left < right
            }

        for relative in targets {
            guard let item = dataSource.canonicalUrl(forRelativePath: relative) else { continue }
            outlineView.expandItem(item)
        }
    }

    func restoreSelection(_ path: String?) {
        guard let path, let outlineView else { return }
        guard let item = dataSource.canonicalUrl(forRelativePath: path) else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func itemDidExpand(_ notification: Notification) {
        guard !dataSource.isSearching, let item = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
        if let relative = dataSource.relativePath(for: item.url) {
            performDeferredUIUpdate {
                if !self.expandedRelativePaths.wrappedValue.contains(relative) {
                    self.expandedRelativePaths.wrappedValue.insert(relative)
                }
            }
        }
    }

    func itemDidCollapse(_ notification: Notification) {
        guard !dataSource.isSearching, let item = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
        if let relative = dataSource.relativePath(for: item.url) {
            performDeferredUIUpdate {
                if self.expandedRelativePaths.wrappedValue.contains(relative) {
                    self.expandedRelativePaths.wrappedValue.remove(relative)
                    self.expandedRelativePaths.wrappedValue = self.expandedRelativePaths.wrappedValue
                        .filter { !$0.hasPrefix(relative + "/") }
                }
            }
        }
    }

    func selectionDidChange(_ notification: Notification) {
        guard !dataSource.isSearching, let outlineView = notification.object as? NSOutlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileTreeItem else {
            performDeferredUIUpdate {
                self.selectedRelativePath.wrappedValue = nil
            }
            return
        }

        if dataSource.isDirectory(item.url) {
            performDeferredUIUpdate {
                self.selectedRelativePath.wrappedValue = nil
            }
        } else {
            let relative = dataSource.relativePath(for: item.url)
            performDeferredUIUpdate {
                if self.selectedRelativePath.wrappedValue != relative {
                    self.selectedRelativePath.wrappedValue = relative
                }
            }
        }
    }

    private func performDeferredUIUpdate(_ work: @MainActor @escaping () -> Void) {
        Task { @MainActor in
            await Task.yield()
            work()
        }
    }
}
