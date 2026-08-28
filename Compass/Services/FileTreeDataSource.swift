//
//  FileTreeDataSource.swift
//  Compass
//
//  Created by AI Assistant on 21/12/2025.
//

import Foundation
import AppKit

/// A stable wrapper for file system items to ensure safe identity in NSOutlineView
final class FileTreeItem: NSObject, Sendable {
    let url: NSURL
    let path: String

    init(url: NSURL) {
        self.url = url
        self.path = url.path ?? ""
        super.init()
    }

    override var hash: Int { path.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FileTreeItem else { return false }
        return path == other.path
    }

    var asURL: URL { url as URL }
}

/// Unified data source and logic manager for the file tree
@MainActor
class FileTreeDataSource: NSObject, NSOutlineViewDataSource {
    private let fileManager = FileManager.default
    private var rootURL: FileTreeItem?
    private var searchQuery: String = ""
    private var loadGeneration: Int = 0

    private var showHiddenFiles: Bool = false

    private var childrenCache: [URL: [FileTreeItem]] = [:]
    private var isDirectoryCache: [URL: Bool] = [:]
    private var itemCache: [URL: FileTreeItem] = [:]
    private var searchResults: [FileTreeItem] = []

    private let cacheLimit = 5_000

    private func evictIfNeeded() {
        if childrenCache.count > cacheLimit { childrenCache.removeAll() }
        if isDirectoryCache.count > cacheLimit { isDirectoryCache.removeAll() }
        if itemCache.count > cacheLimit { itemCache.removeAll() }
    }

    // Stable sentinels to avoid creating new objects in transition states
    private lazy var fallbackItem = FileTreeItem(url: NSURL(fileURLWithPath: "/dev/null"))

    weak var outlineView: NSOutlineView?

    // MARK: - Properties

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Configuration

    func setRootURL(_ url: URL) {
        let item = canonical(url)
        guard rootURL?.path != item.path else { return }

        loadGeneration += 1
        rootURL = item
        resetCaches(includeItemCache: false)
    }

    func setSearchQuery(_ query: String) {
        guard searchQuery != query else { return }
        let wasSearching = isSearching
        searchQuery = query

        if wasSearching != isSearching {
            searchResults.removeAll()
        }
    }

    func resetCaches(includeItemCache: Bool = false) {
        childrenCache.removeAll()
        isDirectoryCache.removeAll()
        searchResults.removeAll()
        if includeItemCache {
            itemCache.removeAll()
        }
    }

    func setShowHiddenFiles(_ show: Bool) {
        guard showHiddenFiles != show else { return }
        showHiddenFiles = show
        resetCaches(includeItemCache: false)
    }

    func canonical(_ url: URL) -> FileTreeItem {
        let standardized = url.standardized
        if let cached = itemCache[standardized] { return cached }
        let item = FileTreeItem(url: standardized as NSURL)
        itemCache[standardized] = item
        return item
    }

    // MARK: - File Info

    func isDirectory(_ url: NSURL) -> Bool {
        let pathURL = url as URL
        if let cached = isDirectoryCache[pathURL] { return cached }
        let isDir = (try? pathURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        isDirectoryCache[pathURL] = isDir
        return isDir
    }

    func relativePath(for url: NSURL) -> String? {
        guard let rootURL = self.rootURL else { return nil }
        let rootPath = rootURL.path
        let path = url.path ?? ""
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? nil : relative
    }

    func url(forRelativePath relative: String) -> URL? {
        guard let rootItem = self.rootURL else { return nil }
        let root = rootItem.asURL
        guard !relative.isEmpty else { return root }
        return root.appendingPathComponent(relative)
    }

    func canonicalUrl(forRelativePath relative: String) -> FileTreeItem? {
        guard let url = url(forRelativePath: relative) else { return nil }
        return canonical(url)
    }

    func displayName(for item: FileTreeItem) -> String {
        if isSearching, let rootURL = self.rootURL {
            let relative = item.path.replacingOccurrences(of: rootURL.path, with: "")
            if relative.isEmpty {
                return item.url.lastPathComponent ?? (item.path as NSString).lastPathComponent
            }
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return item.url.lastPathComponent ?? (item.path as NSString).lastPathComponent
    }

    // MARK: - Data Loading

    private func children(for item: FileTreeItem) -> [FileTreeItem] {
        let url = item.asURL
        if let cached = childrenCache[url] { return cached }
        guard isDirectory(item.url) else {
            childrenCache[url] = []
            return []
        }

        let contents: [URL]
        do {
            let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            )
        } catch {
            childrenCache[url] = []
            return []
        }

        let resultItems: [FileTreeItem] = contents.sorted { left, right in
            let leftIsDir = (try? left.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rightIsDir = (try? right.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if leftIsDir != rightIsDir { return leftIsDir && !rightIsDir }
            return left.lastPathComponent.localizedCaseInsensitiveCompare(right.lastPathComponent) == .orderedAscending
        }.map { canonical($0) }

        childrenCache[url] = resultItems
        for subItem in resultItems {
            let itemPath = subItem.asURL
            let isDir = (try? itemPath.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            isDirectoryCache[itemPath] = isDir
        }
        evictIfNeeded()
        return resultItems
    }

    func setSearchResults(_ results: [FileTreeItem]) {
        self.searchResults = results
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isSearching {
            return item == nil ? searchResults.count : 0
        }

        let targetItem: FileTreeItem
        if let item {
            guard let ftItem = item as? FileTreeItem else { return 0 }
            targetItem = ftItem
        } else {
            guard let root = self.rootURL else { return 0 }
            targetItem = root
        }

        if !isDirectory(targetItem.url) { return 0 }
        return children(for: targetItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isSearching {
            guard index < searchResults.count else { return fallbackItem }
            return searchResults[index]
        }

        let targetItem: FileTreeItem
        if let item {
            guard let ftItem = item as? FileTreeItem else { return fallbackItem }
            targetItem = ftItem
        } else {
            guard let root = self.rootURL else { return fallbackItem }
            targetItem = root
        }

        let children = children(for: targetItem)
        guard index < children.count else { return fallbackItem }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard !isSearching, let ftItem = item as? FileTreeItem, ftItem != fallbackItem else { return false }
        return isDirectory(ftItem.url)
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, writeItems items: [Any], to pasteboard: NSPasteboard) -> Bool {
        guard let item = items.first as? FileTreeItem else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([item.asURL as NSURL])
        return true
    }
}
