import AppKit

@MainActor
final class FileTreeSearchEngine {
    private let dataSource: FileTreeDataSource
    private let appearanceCoordinator: FileTreeAppearanceCoordinator
    weak var outlineView: NSOutlineView?
    var rootURLProvider: (() -> URL?)?
    var onNeedsStructuralRefresh: (() -> Void)?

    private var query = ""
    private var pendingTask: Task<Void, Never>?

    init(dataSource: FileTreeDataSource, appearanceCoordinator: FileTreeAppearanceCoordinator) {
        self.dataSource = dataSource
        self.appearanceCoordinator = appearanceCoordinator
    }

    func updateQuery(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        dataSource.setSearchQuery(newQuery)

        if !newQuery.isEmpty {
            scheduleSearch(query: newQuery)
        } else {
            onNeedsStructuralRefresh?()
        }
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    func reset() {
        cancelPending()
        query = ""
        dataSource.setSearchQuery("")
    }

    // MARK: - Search

    private nonisolated static func enumerateMatches(
        rootURL: URL, query: String, limit: Int
    ) -> [URL] {
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let lowerQuery = query.lowercased()

        while let next = enumerator?.nextObject() as? URL {
            if results.count >= limit { break }
            if next.lastPathComponent.lowercased().contains(lowerQuery) {
                results.append(next)
            }
        }

        return results
    }

    private func scheduleSearch(query: String) {
        let context = SearchContext(generation: query.hashValue, rootURL: rootURLProvider?(), query: query)
        guard !handleEmptySearchQueryIfNeeded(context) else { return }

        if shouldRunSearchSynchronously {
            runSynchronousSearch(context)
        } else {
            scheduleAsynchronousSearch(context)
        }
    }

    private var shouldRunSearchSynchronously: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func handleEmptySearchQueryIfNeeded(_ context: SearchContext) -> Bool {
        if context.query.isEmpty {
            dataSource.resetCaches()
            return true
        }
        return false
    }

    private struct SearchContext {
        let generation: Int
        let rootURL: URL?
        let query: String
    }

    private func canApplySearchResults(_ context: SearchContext) -> Bool {
        context.query == query
    }

    private func applySearchResults(_ results: [URL], context: SearchContext) {
        guard canApplySearchResults(context) else { return }
        let items = results.map { dataSource.canonical($0) }
        dataSource.setSearchResults(items)
        outlineView?.reloadData()
        appearanceCoordinator.applyAppearanceToVisibleRows()
    }

    private func runSynchronousSearch(_ context: SearchContext) {
        guard let rootURL = context.rootURL else { return }
        let results = Self.enumerateMatches(rootURL: rootURL, query: context.query, limit: 500)
        applySearchResults(results, context: context)
    }

    private func scheduleAsynchronousSearch(_ context: SearchContext) {
        guard let rootURL = context.rootURL else { return }

        cancelPending()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            let results = await Task.detached(priority: .userInitiated) {
                Self.enumerateMatches(rootURL: rootURL, query: context.query, limit: 500)
            }.value

            await MainActor.run {
                self.applySearchResults(results, context: context)
            }
        }
    }
}
