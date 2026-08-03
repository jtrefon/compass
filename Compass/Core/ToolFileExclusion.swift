import Foundation

/// Shared file exclusion utility for filesystem tools.
/// Uses the same merged (built-in + agent-maintained `[custom]`) exclude
/// patterns as the codebase index so vendor/dependency directories are hidden
/// from tool output — and stay consistent with what the indexer and grep see.
struct ToolFileExclusion {
    let projectRoot: URL
    private let mergedPatterns: [String]

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.mergedPatterns = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: projectRoot,
            defaultPatterns: IndexConfiguration.default.excludePatterns
        )
    }

    /// Whether a URL should be excluded from tool output.
    func shouldExclude(_ url: URL) -> Bool {
        ToolFileExclusion.isExcluded(url: url, patterns: mergedPatterns)
    }

    /// Whether a directory should have its descendants skipped during
    /// recursive enumeration. Returns false for non-directories.
    func shouldSkipDescendants(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        return shouldExclude(url)
    }

    /// Returns the project-relative path for an absolute URL.
    func relativePath(for url: URL) -> String {
        let rel = url.relativeTo(projectRoot)
        return rel == projectRoot.standardizedFileURL.path ? "" : rel
    }

    /// Returns the relative path of a URL from the project root, or nil if outside.
    func tryRelativePath(for url: URL) -> String? {
        let rel = url.relativeTo(projectRoot)
        guard rel != url.standardizedFileURL.path else { return nil }
        return rel
    }
}

// MARK: - Static matching (patterns supplied by the caller)

extension ToolFileExclusion {
    static func isExcluded(url: URL, patterns: [String] = IndexConfiguration.default.excludePatterns) -> Bool {
        isExcluded(path: url.standardizedFileURL.path, patterns: patterns)
    }

    static func isExcluded(path: String, patterns: [String]) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)

        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.contains("*") {
                let needle = trimmed.replacingOccurrences(of: "*", with: "")
                if !needle.isEmpty, normalized.contains(needle) { return true }
                continue
            }

            if trimmed.contains("/") {
                let needle = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !needle.isEmpty, normalized.contains(needle) { return true }
                continue
            }

            if components.contains(trimmed) { return true }
        }
        return false
    }
}
