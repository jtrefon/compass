import Foundation

public struct FileTreeRefreshRequestedEvent: Event {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}
