import Foundation

enum AppConstantsFileSystem {
    static let maxPathLength = 4096
    static let maxRecentFiles = 10
    static let maxHistoryCount = 50

    /// Name of the project-scoped IDE state directory. Defaults to ".ide".
    /// Override via `IDE_DIR_NAME` environment variable.
    static var projectDirName: String {
        ProcessInfo.processInfo.environment["IDE_DIR_NAME"] ?? ".ide"
    }
}
