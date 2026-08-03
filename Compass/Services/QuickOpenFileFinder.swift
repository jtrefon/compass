import Foundation

struct QuickOpenFileFinder {
    struct ScoredPath: Sendable {
        let relativePath: String
        let score: Int
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func findFiles(query: String, root: URL, limit: Int) -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let needle = trimmedQuery.lowercased()
        var hits: [ScoredPath] = []

        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if values?.isDirectory == true {
                if shouldSkipDirectory(url) {
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let relativePath = makeRelativePath(url: url, root: root)
            let score = score(relativePath: relativePath, fileName: url.lastPathComponent, needle: needle)
            if score > 0 {
                hits.append(ScoredPath(relativePath: relativePath, score: score))
            }

            if hits.count > limit * 20 {
                break
            }
        }

        return sortedPaths(from: hits, limit: limit)
    }

    private func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == ".git" || name == AppConstantsFileSystem.projectDirName || name == "node_modules"
    }

    private func makeRelativePath(url: URL, root: URL) -> String {
        if url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        return url.lastPathComponent
    }

    private func score(relativePath: String, fileName: String, needle: String) -> Int {
        let lowerRelative = relativePath.lowercased()
        let lowerBase = fileName.lowercased()

        var score = 0
        if lowerBase == needle { score += 1000 }
        if lowerBase.hasPrefix(needle) { score += 700 }
        if lowerBase.contains(needle) { score += 500 }
        if lowerRelative.hasPrefix(needle) { score += 250 }
        if lowerRelative.contains(needle) { score += 100 }
        return score
    }

    private func sortedPaths(from hits: [ScoredPath], limit: Int) -> [String] {
        let sorted = hits.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.relativePath < right.relativePath
        }

        return Array(sorted.prefix(limit)).map { $0.relativePath }
    }
}
