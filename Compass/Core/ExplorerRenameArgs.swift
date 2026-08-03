import Foundation

public struct ExplorerRenameArgs: Codable, Sendable {
    public let path: String
    public let newName: String

    public init(path: String, newName: String) {
        self.path = path
        self.newName = newName
    }
}
