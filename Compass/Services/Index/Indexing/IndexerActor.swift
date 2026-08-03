import Foundation

public actor IndexerActor {
    private let database: DatabaseStore
    private let config: IndexConfiguration
    private let projectRoot: URL?

    private static let supportedExtensions = AppConstantsIndexing.indexableExtensions

    public init(
        database: DatabaseStore,
        config: IndexConfiguration = .default,
        projectRoot: URL? = nil
    ) {
        self.database = database
        self.config = config
        self.projectRoot = projectRoot
    }

    public func indexFile(at url: URL) async throws {
        guard !shouldExclude(url) else { return }
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { return }

        let resourceId = url.absoluteString
        let fileModTime = fileModificationTime(at: url)

        if let existingModTime = try? await database.getResourceLastModified(resourceId: resourceId),
           let fileModTime,
           abs(existingModTime - fileModTime) < 0.001 {
            return
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let symbols = SymbolExtractor.extract(from: url, content: content)
        let timestamp = fileModTime ?? Date().timeIntervalSince1970

        try await database.upsertResource(
            UpsertResourceRequest(
                resourceId: resourceId,
                path: url.path,
                language: url.pathExtension.lowercased(),
                timestamp: timestamp
            )
        )

        guard !symbols.isEmpty else { return }
        try await database.deleteSymbolsByFile(filePath: url.path)
        try await database.deleteSymbols(for: resourceId)
        try await database.insertSymbols(symbols)
        // Also write to legacy symbols table for searchSymbols/searchSymbolsWithPaths
        try await database.saveSymbols(symbols.map { sym in
            Symbol(
                id: UUID().uuidString,
                resourceId: resourceId,
                name: sym.name,
                kind: SymbolKind(rawValue: sym.kind) ?? .unknown,
                lineStart: sym.lineStart,
                lineEnd: sym.lineEnd,
                description: nil
            )
        })
    }

    public func removeFile(at url: URL) async throws {
        let resourceId = url.absoluteString
        try await database.deleteResource(resourceId: resourceId)
        try await database.deleteSymbols(for: resourceId)
        try await database.deleteSymbolsByFile(filePath: url.path)
    }

    func getResourceLastModified(resourceId: String) async throws -> Double? {
        try await database.getResourceLastModified(resourceId: resourceId)
    }

    func pruneResourcesNotInPaths(_ knownPaths: Set<String>) async throws -> Int {
        try await database.pruneResourcesNotInPaths(knownPaths)
    }

    private func shouldExclude(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/")

        let relativePath: String
        if let projectRoot {
            let rootPath = projectRoot.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix(rootPath + "/") {
                relativePath = String(path.dropFirst(rootPath.count + 1))
            } else if path == rootPath {
                relativePath = ""
            } else {
                relativePath = path
            }
        } else {
            relativePath = path
        }

        for pattern in config.excludePatterns {
            if GlobMatcher.match(path: relativePath, pattern: pattern) {
                return true
            }
            let components = relativePath.split(separator: "/").map(String.init)
            if components.contains(pattern) {
                return true
            }
        }

        return false
    }

    private func fileModificationTime(at url: URL) -> Double? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
    }
}
