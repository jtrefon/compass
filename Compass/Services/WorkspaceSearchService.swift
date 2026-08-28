import Foundation

public struct WorkspaceSearchMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let line: Int
    public let snippet: String

    public init(relativePath: String, line: Int, snippet: String) {
        self.relativePath = relativePath
        self.line = line
        self.snippet = snippet
        self.id = "\(relativePath):\(line):\(snippet)"
    }
}

@MainActor
public final class WorkspaceSearchService {
    private let codebaseIndexProvider: () -> CodebaseIndexProtocol?
    private let settingsStore: SettingsStore

    public init(codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?) {
        self.codebaseIndexProvider = codebaseIndexProvider
        self.settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
    }

    public func search(pattern: String, projectRoot: URL, limit: Int = 200) async -> [WorkspaceSearchMatch] {
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return [] }

        if let index = codebaseIndexProvider(),
           settingsStore.bool(forKey: AppConstantsStorage.codebaseIndexEnabledKey, default: true),
           let matches = try? await index.searchIndexedText(pattern: needle, limit: limit) {
            return matches.compactMap(Self.parseIndexedMatchLine)
        }

        return await fallbackSearch(pattern: needle, projectRoot: projectRoot, limit: limit)
    }

    private func fallbackSearch(pattern: String, projectRoot: URL, limit: Int) async -> [WorkspaceSearchMatch] {
        await WorkspaceFallbackSearcher().search(pattern: pattern, projectRoot: projectRoot, limit: limit)
    }

    static func parseIndexedMatchLine(_ line: String) -> WorkspaceSearchMatch? {
        // Expected: rel/path:line: snippet
        // We split the first two ":" occurrences.
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        let path = String(parts[0])
        let lineStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let line = Int(lineStr) ?? 1
        let snippet = parts.count >= 3 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""

        return WorkspaceSearchMatch(relativePath: path, line: line, snippet: snippet)
    }
}
