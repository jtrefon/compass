import Foundation

public struct IDEFileDeletedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
