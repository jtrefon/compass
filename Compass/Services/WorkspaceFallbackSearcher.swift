import Foundation

struct WorkspaceFallbackSearcher {
    private let fileManager: FileManager
    private let allowedExtensions: Set<String>

    init(
        fileManager: FileManager = .default,
        allowedExtensions: Set<String> = Set(AppConstantsIndexing.allowedExtensions)
    ) {
        self.fileManager = fileManager
        self.allowedExtensions = allowedExtensions
    }

    func search(pattern: String, projectRoot: URL, limit: Int) async -> [WorkspaceSearchMatch] {
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        let root = projectRoot.standardizedFileURL
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var output: [WorkspaceSearchMatch] = []
        output.reserveCapacity(min(limit, 64))

        while let url = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }

            if shouldSkipDescendantsIfDirectory(url, enumerator: enumerator) {
                continue
            }

            if let matches = matchesInFileIfApplicable(url: url, root: root, needle: needle, limit: limit - output.count) {
                output.append(contentsOf: matches)
                if output.count >= limit { break }
            }
        }

        return output
    }

    private func shouldSkipDescendantsIfDirectory(_ url: URL, enumerator: FileManager.DirectoryEnumerator?) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return false }
        if shouldSkipDirectory(url) {
            enumerator?.skipDescendants()
        }
        return true
    }

    private func matchesInFileIfApplicable(url: URL, root: URL, needle: String, limit: Int) -> [WorkspaceSearchMatch]? {
        guard limit > 0 else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        guard shouldSearchFile(url) else { return nil }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        return buildMatches(
            MatchBuildRequest(
                content: content,
                url: url,
                root: root,
                pattern: needle,
                limit: limit
            )
        )
    }

    private func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == ".git" || name == AppConstantsFileSystem.projectDirName || name == "node_modules"
    }

    private func shouldSearchFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        return allowedExtensions.contains(ext)
    }

    private struct MatchBuildRequest {
        let content: String
        let url: URL
        let root: URL
        let pattern: String
        let limit: Int
    }

    private func buildMatches(_ request: MatchBuildRequest) -> [WorkspaceSearchMatch] {
        let lines = request.content.components(separatedBy: .newlines)
        let relative = makeRelativePath(url: request.url, root: request.root)
        var output: [WorkspaceSearchMatch] = []
        output.reserveCapacity(min(request.limit, 8))

        for (idx, line) in lines.enumerated() {
            if Task.isCancelled { break }
            if !line.contains(request.pattern) { continue }

            output.append(
                WorkspaceSearchMatch(
                    relativePath: relative,
                    line: idx + 1,
                    snippet: makeSnippet(from: line)
                )
            )

            if output.count >= request.limit { break }
        }

        return output
    }

    private func makeRelativePath(url: URL, root: URL) -> String {
        if url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        return url.lastPathComponent
    }

    private func makeSnippet(from line: String) -> String {
        let snippetMax = 240
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > snippetMax {
            return String(trimmed.prefix(snippetMax)) + "…"
        }
        return trimmed
    }
}
