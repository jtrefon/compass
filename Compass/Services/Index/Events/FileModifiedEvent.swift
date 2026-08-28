import Foundation

public struct FileModifiedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
