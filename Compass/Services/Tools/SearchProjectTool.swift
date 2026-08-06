import Foundation

/// Comprehensive project search tool.
/// Combines index symbol search, full-text search, grep, and filename matching
/// into a single call. Returns ALL occurrences of a query with type, location, and context.
struct SearchProjectTool: AITool {
    let name = "search"
let description =        "Search the codebase: symbols, text, and filenames, grouped by file. Paginated via offset/max_results."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search term (class, function, variable, text). Case-insensitive."
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Maximum results to return (default 50, max 200)."
                ],
                "offset": [
                    "type": "integer",
                    "description": "Number of results to skip for pagination (default 0). Use with max_results to page through large result sets."
                ]
            ],
            "required": ["query"]
        ]
    }

    let index: CodebaseIndexProtocol?
    let projectRoot: URL
    private let fileExclusion: ToolFileExclusion

    init(index: CodebaseIndexProtocol?, projectRoot: URL) {
        self.index = index
        self.projectRoot = projectRoot
        self.fileExclusion = ToolFileExclusion(projectRoot: projectRoot)
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        guard let query = raw["query"] as? String else {
            return "Missing 'query' argument."
        }
        let maxResults = min(200, max(1, raw["max_results"] as? Int ?? 50))
        let offset = max(0, raw["offset"] as? Int ?? 0)
        // Fetch offset+page from each source so `offset` pagination actually
        // returns a next page (was capped at maxResults -> always empty).
        let fetchLimit = min(500, maxResults + offset)
        let lowerQuery = query.lowercased()

        let execStart = ContinuousClock.now

        var entries: [SearchEntry] = []

        // 1. Vector semantic search via index (best for conceptual relevance)
        if let index {
            // Semantic search via MLX embeddings removed — RAG handles contextual retrieval
        }

        // 2. Symbol search via index (authoritative for code structure)
        if let index {
            let symbolCount: Int
            if let symbols = try? await index.searchSymbolsWithPaths(nameLike: query, limit: fetchLimit) {
                symbolCount = symbols.count
                for symbolResult in symbols {
                    let kind = classifySymbolKind(symbolResult.symbol.kind)
                    let filePath = symbolResult.filePath ?? "unknown"
                    let line = symbolResult.symbol.lineStart
                    entries.append(SearchEntry(
                        file: filePath,
                        line: line,
                        matchType: kind,
                        context: "\(kind) \(symbolResult.symbol.name)"
                    ))
                }
            } else {
                symbolCount = 0
            }


            // 2. Full-text search via index
            if entries.count < maxResults {
                let textCount: Int
                if let textMatches = try? await index.searchIndexedText(pattern: query, limit: fetchLimit) {
                    textCount = textMatches.count
                    for match in textMatches {
                        // Format: file:line: snippet
                        let parts = match.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count >= 3 {
                            let file = String(parts[0])
                            let line = Int(parts[1]) ?? 0
                            let context = String(parts[2]).trimmingCharacters(in: .whitespaces)
                            entries.append(SearchEntry(file: file, line: line, matchType: "reference", context: context))
                        }
                    }
                } else {
                    textCount = 0
                }
            }
        }

        // 3. Filesystem grep (fallback — only when index returns nothing)
        if entries.isEmpty {
            let grepResults = try await grepFilesystem(query: lowerQuery, maxResults: fetchLimit)
            if !grepResults.isEmpty {
                entries.append(contentsOf: grepResults)
            }
        }

        // 4. Filename search (fallback — only when nothing found)
        if entries.isEmpty {
            let fileResults = findFilesByName(query: lowerQuery, maxResults: fetchLimit)
            if !fileResults.isEmpty {
                entries.append(contentsOf: fileResults)
            }
        }

        let totalMs = Self.milliseconds(execStart.duration(to: ContinuousClock.now))

        guard !entries.isEmpty else {
            return "No matches found for '\(query)'."
        }

        let pageEntries = offset > 0 ? Array(entries.dropFirst(offset)) : entries
        let page = Array(pageEntries.prefix(maxResults))
        let totalAvailable = entries.count

        let formatted = formatResults(entries: page, query: query)
        if totalAvailable > offset + page.count {
            let shownStart = offset + 1
            let shownEnd = offset + page.count
            return formatted + "\n\n[showing \(shownStart)-\(shownEnd) of \(totalAvailable) matches — use `offset=\(shownEnd)` max_results=\(maxResults) to see the next page]"
        }
        if offset > 0 {
            return formatted + "\n\n[showing \(page.count) remaining matches of \(totalAvailable) — end of results]"
        }
        return formatted
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Search Methods

    /// Files larger than this are skipped by the grep fallback — a minified
    /// bundle or vendored artifact would otherwise blow the tool budget.
    private static let maxSearchableFileBytes = 1_048_576

    /// Binary/heavy files are skipped: UTF-8 read of binary content is
    /// meaningless for the model and wastes the read budget.
    private static func isSearchableContent(_ content: String, sizeBytes: Int) -> Bool {
        guard sizeBytes <= maxSearchableFileBytes else { return false }
        return !content.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func grepFilesystem(query: String, maxResults: Int) async throws -> [SearchEntry] {
        var results: [SearchEntry] = []
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        while let fileURL = enumerator.nextObject() as? URL {
            if results.count >= maxResults { break }
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if fileExclusion.shouldSkipDescendants(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                  Self.isSearchableContent(content, sizeBytes: (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) else { continue }
            let lines = content.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                if results.count >= maxResults { break }
                if line.lowercased().contains(query) {
                    let absPath = absolutePath(fileURL)
                    let ctx = line.trimmingCharacters(in: .whitespaces)
                    results.append(SearchEntry(file: absPath, line: i + 1, matchType: "reference", context: ctx))
                }
            }
        }
        return results
    }

    private func findFilesByName(query: String, maxResults: Int) -> [SearchEntry] {
        var results: [SearchEntry] = []
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        while let fileURL = enumerator.nextObject() as? URL {
            if results.count >= maxResults { break }
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if fileExclusion.shouldSkipDescendants(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let name = fileURL.lastPathComponent.lowercased()
            if name.contains(query) {
                    results.append(SearchEntry(
                        file: absolutePath(fileURL),
                        line: 0,
                        matchType: "filename",
                        context: fileURL.lastPathComponent
                    ))
            }
        }
        return results
    }

    // MARK: - Formatting

    private func formatResults(entries: [SearchEntry], query: String) -> String {
        let grouped = Dictionary(grouping: entries) { $0.file }
            .sorted { $0.key < $1.key }

        var output = "Found \(entries.count) occurrence(s) of \"\(query)\":\n\n"
        for (file, fileEntries) in grouped {
            output += "# \(file)\n"
            for entry in fileEntries {
                let lineInfo = entry.line > 0 ? "\(entry.line): " : ""
                output += "  \(lineInfo)[\(entry.matchType)] \(entry.context)\n"
            }
            output += "\n"
        }
        return output
    }

    // MARK: - Helpers

    private func absolutePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func classifySymbolKind(_ kind: SymbolKind) -> String {
        switch kind {
        case .class: return "class"
        case .struct: return "struct"
        case .enum: return "enum"
        case .protocol: return "interface"
        case .extension: return "extension"
        case .function: return "function"
        case .variable: return "variable"
        case .initializer: return "initializer"
        case .unknown: return "symbol"
        }
    }

    private struct SearchEntry: Sendable {
        let file: String
        let line: Int
        let matchType: String
        let context: String
    }
}
