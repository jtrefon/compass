import Foundation

public struct IDEFileModifiedEvent: Event {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
