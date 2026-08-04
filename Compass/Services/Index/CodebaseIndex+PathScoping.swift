import Foundation

extension CodebaseIndex {
    func isPathWithinProjectRoot(_ absolutePath: String) -> Bool {
        let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let rootPath = projectRoot.standardizedFileURL.path
        return normalized == rootPath || normalized.hasPrefix(rootPath + "/")
    }

    func scopedRelativePath(from absolutePath: String) -> String? {
        guard isPathWithinProjectRoot(absolutePath) else { return nil }
        let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let rootPath = projectRoot.standardizedFileURL.path
        if normalized == rootPath {
            return "."
        }
        return String(normalized.dropFirst(rootPath.count + 1))
    }

    func pathFromResourceId(_ resourceId: String) -> String? {
        if let url = URL(string: resourceId), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return nil
    }
}
