import Foundation

extension CodebaseIndex {
    /// Patterns usable as grep `--exclude-dir` (simple dir names, no globs).
    static func excludeDirPatterns(projectRoot: URL) -> [String] {
        let merged = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: projectRoot,
            defaultPatterns: IndexConfiguration.default.excludePatterns
        )
        return merged.filter { pattern in
            !pattern.contains("*")
                && !pattern.contains("/")
                && !pattern.hasPrefix(".")
                && pattern != AppConstantsFileSystem.projectDirName
        }
    }

    public func searchSymbols(nameLike query: String, limit: Int) async throws -> [Symbol] {
        try await ensureReady()
        return try await queryService.searchSymbols(nameLike: query, limit: limit)
    }

    public func searchSymbolsWithPaths(nameLike query: String, limit: Int) async throws -> [SymbolSearchResult] {
        try await ensureReady()
        return try await queryService.searchSymbolsWithPaths(nameLike: query, limit: limit)
    }

    public func searchIndexedText(pattern: String, limit: Int = 100) async throws -> [String] {
        try await ensureReady()
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return [] }

        let boundedLimit = max(1, min(500, limit))

        // Use grep for fast text search — 10-100x faster than reading each
        // file line-by-line in Swift. Searches all indexed file types.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        let exts = ["swift", "js", "jsx", "ts", "tsx", "mjs", "py", "php"]
        let extArgs = exts.flatMap { ["--include", "*.\($0)"] }
        // Skip VCS dirs and dependency/derived-data directories: the index
        // never indexes them, and scanning them is pure waste. Custom
        // patterns from .ide/index_exclude ([custom] section, maintained by
        // the agent) are translated into --exclude-dir entries so tool output
        // and index views stay consistent.
        var excludeArgs: [String] = []
        for pattern in Self.excludeDirPatterns(projectRoot: projectRoot) {
            excludeArgs += ["--exclude-dir", pattern]
        }
        // -F: the model's query is a LITERAL string, not a regex.
        task.arguments = ["-rn", "--no-messages", "-F"] + excludeArgs + extArgs
            + ["-m", String(min(boundedLimit, 50)),
               "-i", needle,
               projectRoot.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        // Run off the cooperative pool with a timeout and cancellation:
        // the previous implementation blocked the calling thread for the
        // entire scan with no way to interrupt a huge repository.
        let data: Data
        do {
            data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    try task.run()
                    let output = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    return output
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw CancellationError()
                }
                let first = try await group.next()
                group.cancelAll()
                guard let first else { throw CancellationError() }
                if task.isRunning {
                    task.terminate()
                    task.waitUntilExit()
                }
                return first
            }
        } catch {
            task.terminate()
            return []
        }

        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        // Parse grep output and convert absolute paths to project-relative paths
        let grepLines = output.components(separatedBy: .newlines)
        let rootPrefix = projectRoot.path.hasSuffix("/") ? projectRoot.path : projectRoot.path + "/"
        var results: [String] = []
        for line in grepLines {
            guard !line.isEmpty, results.count < boundedLimit else { break }
            // Convert absolute path to relative — grep outputs "path:line:content"
            var display = line
            if line.hasPrefix(rootPrefix) {
                display = String(line.dropFirst(rootPrefix.count))
            } else if let pathRange = line.range(of: rootPrefix) {
                display = String(line[pathRange.upperBound...])
            }
            let snippet = display.count > 300 ? String(display.prefix(300)) + "…" : display
            results.append(snippet)
        }
        return results
    }
}
