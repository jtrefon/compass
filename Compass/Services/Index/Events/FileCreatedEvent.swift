import Foundation

public struct FileCreatedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
