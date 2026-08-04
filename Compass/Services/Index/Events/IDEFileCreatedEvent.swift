import Foundation

public struct IDEFileCreatedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
