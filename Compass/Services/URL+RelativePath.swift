import Foundation

extension URL {
    /// Returns the receiver's path relative to a root directory.
    /// If the receiver is not under `root`, returns the receiver's absolute path.
    func relativeTo(_ root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = self.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

extension String {
    /// Returns `self` made relative to a root directory path.
    /// If `self` is not under `root`, returns `self` unchanged.
    func relativeToRoot(_ root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        guard hasPrefix(rootPath + "/") else { return self }
        return String(dropFirst(rootPath.count + 1))
    }
}
