import Foundation

public struct FileDeletedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
