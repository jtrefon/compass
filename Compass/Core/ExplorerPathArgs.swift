import Foundation

public struct ExplorerPathArgs: Codable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}
