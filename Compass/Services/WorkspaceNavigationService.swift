import Foundation

public struct WorkspaceCodeLocation: Identifiable, Equatable, Sendable {
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

public enum WorkspaceNavigationError: LocalizedError {
    case missingSymbol
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .missingSymbol:
            return "No symbol selected"
        case .invalidIdentifier(let value):
            return "Invalid identifier: \(value)"
        }
    }
}

@MainActor
public final class WorkspaceNavigationService {
    private let codebaseIndexProvider: () -> CodebaseIndexProtocol?
    private let settingsStore: SettingsStore

    public struct FindDefinitionRequest {
        public let identifier: String
        public let projectRoot: URL
        public let currentFilePath: String?
        public let currentContent: String
        public let currentLanguage: String
        public let limit: Int
    }

    public init(codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?) {
        self.codebaseIndexProvider = codebaseIndexProvider
        self.settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
    }

    public func identifierUnderCursor(text: String, cursor: Int) -> String? {
        Self.identifierAtCursor(in: text, cursor: cursor)
    }

    public func findDefinitionLocations(_ request: FindDefinitionRequest) async -> [WorkspaceCodeLocation] {
        let needle = request.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        if let indexed = await findDefinitionLocationsUsingIndexIfAvailable(request, needle: needle) {
            return indexed
        }

        return await findDefinitionLocationsUsingFallback(request, needle: needle)
    }

    private func findDefinitionLocationsUsingIndexIfAvailable(
        _ request: FindDefinitionRequest,
        needle: String
    ) async -> [WorkspaceCodeLocation]? {
        guard let index = codebaseIndexProvider() else { return nil }
        guard settingsStore.bool(forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true) else { return nil }
        guard let hits = try? await index.searchSymbolsWithPaths(nameLike: needle, limit: request.limit) else { return nil }

        let mapped = mapSymbolSearchResultsToLocations(hits, projectRoot: request.projectRoot)
        let exact = mapped.filter { $0.snippet.hasSuffix(" \(needle)") }
        return exact.isEmpty ? mapped : exact
    }

    private func findDefinitionLocationsUsingFallback(
        _ request: FindDefinitionRequest,
        needle: String
    ) async -> [WorkspaceCodeLocation] {
        let symbolSearch = WorkspaceSymbolSearchService(codebaseIndexProvider: codebaseIndexProvider)
        let results = await symbolSearch.search(
            WorkspaceSymbolSearchService.SearchRequest(
                rawQuery: needle,
                projectRoot: request.projectRoot,
                currentFilePath: request.currentFilePath,
                currentContent: request.currentContent,
                currentLanguage: request.currentLanguage,
                limit: request.limit
            )
        )

        let exact = results.filter { $0.name == needle }
        return exact.map {
            WorkspaceCodeLocation(
                relativePath: $0.relativePath,
                line: $0.line,
                snippet: "\($0.kind.rawValue) \($0.name)"
            )
        }
    }

    private func mapSymbolSearchResultsToLocations(
        _ hits: [SymbolSearchResult],
        projectRoot: URL
    ) -> [WorkspaceCodeLocation] {
        hits.compactMap { hit -> WorkspaceCodeLocation? in
            guard let filePath = hit.filePath else { return nil }
            let rel = Self.relativePath(projectRoot: projectRoot, filePath: filePath)
            return WorkspaceCodeLocation(
                relativePath: rel,
                line: max(1, hit.symbol.lineStart),
                snippet: "\(hit.symbol.kind.rawValue) \(hit.symbol.name)"
            )
        }
    }

    public func findReferenceLocations(
        identifier: String,
        projectRoot: URL,
        limit: Int = 500
    ) async -> [WorkspaceCodeLocation] {
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return [] }

        let searchService = WorkspaceSearchService(codebaseIndexProvider: codebaseIndexProvider)
        let matches = await searchService.search(pattern: needle, projectRoot: projectRoot, limit: limit)

        let filtered = matches.filter { Self.containsWholeWord($0.snippet, word: needle) }
        return filtered.map { WorkspaceCodeLocation(relativePath: $0.relativePath, line: $0.line, snippet: $0.snippet) }
    }

    public func renameInCurrentBuffer(
        content: String,
        identifier: String,
        newName: String
    ) throws -> (updated: String, replacements: Int) {
        try Self.renameInCurrentBuffer(content: content, identifier: identifier, newName: newName)
    }

    public static func identifierAtCursor(in text: String, cursor: Int) -> String? {
        let ns = text as NSString
        if ns.length == 0 { return nil }

        var idx = max(0, min(cursor, ns.length))
        if idx == ns.length {
            idx = max(0, ns.length - 1)
        }

        func isIdentChar(_ ch: unichar) -> Bool {
            if ch >= 48 && ch <= 57 { return true } // 0-9
            if ch >= 65 && ch <= 90 { return true } // A-Z
            if ch >= 97 && ch <= 122 { return true } // a-z
            if ch == 95 { return true } // _
            return false
        }

        if !isIdentChar(ns.character(at: idx)) {
            if idx > 0, isIdentChar(ns.character(at: idx - 1)) {
                idx -= 1
            } else {
                return nil
            }
        }

        var start = idx
        while start > 0, isIdentChar(ns.character(at: start - 1)) {
            start -= 1
        }

        var end = idx
        while end + 1 < ns.length, isIdentChar(ns.character(at: end + 1)) {
            end += 1
        }

        let range = NSRange(location: start, length: end - start + 1)
        let candidate = ns.substring(with: range)
        return isValidIdentifier(candidate) ? candidate : nil
    }

    public static func renameInCurrentBuffer(
        content: String,
        identifier: String,
        newName: String
    ) throws -> (updated: String, replacements: Int) {
        let old = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !old.isEmpty else {
            throw WorkspaceNavigationError.missingSymbol
        }

        guard isValidIdentifier(replacement) else {
            throw WorkspaceNavigationError.invalidIdentifier(replacement)
        }

        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = "\\b\(escaped)\\b"
        let regex = try NSRegularExpression(pattern: pattern)

        let ns = content as NSString
        let matches = regex.numberOfMatches(in: content, range: NSRange(location: 0, length: ns.length))
        let updated = regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: replacement
        )
        return (updated, matches)
    }

    public static func isValidIdentifier(_ candidate: String) -> Bool {
        if candidate.isEmpty { return false }
        let ns = candidate as NSString
        let first = ns.character(at: 0)
        if !isIdentifierStartCharacter(first) { return false }

        for index in 1..<ns.length {
            let ch = ns.character(at: index)
            if !isIdentifierContinuationCharacter(ch) { return false }
        }

        return true
    }

    private static func isIdentifierStartCharacter(_ ch: unichar) -> Bool {
        isASCIIAlphabetic(ch) || ch == 95
    }

    private static func isIdentifierContinuationCharacter(_ ch: unichar) -> Bool {
        isIdentifierStartCharacter(ch) || isASCIIDigit(ch)
    }

    private static func isASCIIAlphabetic(_ ch: unichar) -> Bool {
        (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
    }

    private static func isASCIIDigit(_ ch: unichar) -> Bool {
        ch >= 48 && ch <= 57
    }

    private static func containsWholeWord(_ text: String, word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "\\b\(escaped)\\b"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return (regex?.firstMatch(in: text, range: range) != nil)
    }

    private static func relativePath(projectRoot: URL, filePath: String) -> String {
        let url = URL(fileURLWithPath: filePath)
        let rel = url.relativeTo(projectRoot)
        if rel != url.standardizedFileURL.path { return rel }
        return url.lastPathComponent
    }
}
