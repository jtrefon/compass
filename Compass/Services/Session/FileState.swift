import Foundation

public struct FileState: Codable, Sendable {
    public var lastOpenFileRelativePath: String?
    public var openTabRelativePaths: [String]
    public var activeTabRelativePath: String?

    public init(
        lastOpenFileRelativePath: String? = nil,
        openTabRelativePaths: [String] = [],
        activeTabRelativePath: String? = nil
    ) {
        self.lastOpenFileRelativePath = lastOpenFileRelativePath
        self.openTabRelativePaths = openTabRelativePaths
        self.activeTabRelativePath = activeTabRelativePath
    }
}
