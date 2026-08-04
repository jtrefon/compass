import Foundation

public struct FileTreeState: Codable, Sendable {
    public var fileTreeExpandedRelativePaths: [String]
    public var languageOverridesByRelativePath: [String: String]

    public init(
        fileTreeExpandedRelativePaths: [String] = [],
        languageOverridesByRelativePath: [String: String] = [:]
    ) {
        self.fileTreeExpandedRelativePaths = fileTreeExpandedRelativePaths
        self.languageOverridesByRelativePath = languageOverridesByRelativePath
    }
}
