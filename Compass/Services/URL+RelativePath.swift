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
