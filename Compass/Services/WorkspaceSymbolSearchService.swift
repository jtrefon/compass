import Foundation

struct WorkspaceSymbolLocation: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: SymbolKind
    let relativePath: String
    let line: Int
}

@MainActor
final class WorkspaceSymbolSearchService {
    private let codebaseIndexProvider: () -> CodebaseIndexProtocol?
    private let settingsStore: SettingsStore

    struct SearchRequest {
        let rawQuery: String
        let projectRoot: URL
        let currentFilePath: String?
        let currentContent: String?
        let currentLanguage: String?
        let limit: Int
    }

    init(codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?) {
        self.codebaseIndexProvider = codebaseIndexProvider
        self.settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
    }

    func search(_ request: SearchRequest) async -> [WorkspaceSymbolLocation] {
        let needle = request.rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            return searchCurrentFileWhenQueryEmpty(request)
        }

        if let indexed = await searchUsingIndexIfAvailable(request, needle: needle) {
            return indexed
        }

        return searchCurrentBufferFallback(request, needle: needle)
    }

    private func searchCurrentFileWhenQueryEmpty(_ request: SearchRequest) -> [WorkspaceSymbolLocation] {
        guard let currentFilePath = request.currentFilePath,
              let currentContent = request.currentContent,
              let currentLanguage = request.currentLanguage else { return [] }
        guard let rel = Self.relativePath(projectRoot: request.projectRoot, absolutePath: currentFilePath) else { return [] }

        let parsed = parseSymbols(
            language: currentLanguage,
            content: currentContent,
            resourceId: URL(fileURLWithPath: currentFilePath).absoluteString
        )
        return parsed.prefix(request.limit).map { sym in
            makeWorkspaceSymbolLocation(relativePath: rel, name: sym.name, kind: sym.kind, line: sym.line)
        }
    }

    private func searchUsingIndexIfAvailable(
        _ request: SearchRequest,
        needle: String
    ) async -> [WorkspaceSymbolLocation]? {
        guard let index = codebaseIndexProvider() else { return nil }
        guard settingsStore.bool(forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true) else { return nil }
        let indexedLimit = max(1, min(200, request.limit))
        guard let matches = try? await index.searchSymbolsWithPaths(nameLike: needle, limit: indexedLimit) else { return nil }

        let mapped = mapIndexedMatchesToLocations(matches, projectRoot: request.projectRoot, limit: request.limit)
        return sort(mapped, query: needle)
    }

    private func mapIndexedMatchesToLocations(
        _ matches: [SymbolSearchResult],
        projectRoot: URL,
        limit: Int
    ) -> [WorkspaceSymbolLocation] {
        var out: [WorkspaceSymbolLocation] = []
        out.reserveCapacity(min(limit, matches.count))

        for match in matches {
            guard let filePath = match.filePath else { continue }
            guard let rel = Self.relativePath(projectRoot: projectRoot, absolutePath: filePath) else { continue }

            let symbol = match.symbol
            out.append(
                makeWorkspaceSymbolLocation(
                    relativePath: rel,
                    name: symbol.name,
                    kind: symbol.kind,
                    line: max(1, symbol.lineStart)
                )
            )

            if out.count >= limit { break }
        }

        return out
    }

    private func searchCurrentBufferFallback(
        _ request: SearchRequest,
        needle: String
    ) -> [WorkspaceSymbolLocation] {
        guard let currentFilePath = request.currentFilePath,
              let currentContent = request.currentContent,
              let currentLanguage = request.currentLanguage else { return [] }
        guard let rel = Self.relativePath(projectRoot: request.projectRoot, absolutePath: currentFilePath) else { return [] }

        let parsed = parseSymbols(
            language: currentLanguage,
            content: currentContent,
            resourceId: URL(fileURLWithPath: currentFilePath).absoluteString
        )
        let lowerNeedle = needle.lowercased()
        let filtered = parsed.filter { $0.name.lowercased().contains(lowerNeedle) }
        let limited = filtered.prefix(request.limit).map { sym in
            makeWorkspaceSymbolLocation(relativePath: rel, name: sym.name, kind: sym.kind, line: sym.line)
        }
        return sort(Array(limited), query: needle)
    }

    private func makeWorkspaceSymbolLocation(
        relativePath: String,
        name: String,
        kind: SymbolKind,
        line: Int
    ) -> WorkspaceSymbolLocation {
        WorkspaceSymbolLocation(
            id: "\(relativePath):\(line):\(kind.rawValue):\(name)",
            name: name,
            kind: kind,
            relativePath: relativePath,
            line: line
        )
    }

    private func parseSymbols(
        language: String,
        content: String,
        resourceId: String
    ) -> [(name: String, kind: SymbolKind, line: Int)] {
        if let codeLanguage = CodeLanguage(rawValue: language.lowercased()),
           let module = LanguageModuleManager.shared.getModule(for: codeLanguage) {
            return module.parseSymbols(content: content, resourceId: resourceId)
                .map { (name: $0.name, kind: $0.kind, line: $0.lineStart) }
        }

        return []
    }

    private func sort(_ items: [WorkspaceSymbolLocation], query: String) -> [WorkspaceSymbolLocation] {
        let needle = query.lowercased()

        func score(_ name: String) -> Int {
            let lowercasedName = name.lowercased()
            if lowercasedName == needle { return 1_000 }
            if lowercasedName.hasPrefix(needle) { return 700 }
            if lowercasedName.contains(needle) { return 500 }
            return 0
        }

        return items.sorted { left, right in
            let sa = score(left.name)
            let sb = score(right.name)
            if sa != sb { return sa > sb }
            if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
            if left.line != right.line { return left.line < right.line }
            return left.name < right.name
        }
    }

    static func relativePath(projectRoot: URL, absolutePath: String) -> String? {
        let url = URL(fileURLWithPath: absolutePath)
        let rel = url.relativeTo(projectRoot)
        guard rel != url.standardizedFileURL.path else { return nil }
        return rel
    }
}
