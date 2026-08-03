import Foundation

public struct FileRenamedEvent: Event {
    public let oldUrl: URL
    public let newUrl: URL

    public init(oldUrl: URL, newUrl: URL) {
        self.oldUrl = oldUrl
        self.newUrl = newUrl
    }
}
