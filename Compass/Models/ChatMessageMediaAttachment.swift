import Foundation

public enum ChatMessageMediaKind: String, Codable, Sendable {
    case image
    case video
}

public struct ChatMessageMediaAttachment: Codable, Sendable, Equatable {
    public let kind: ChatMessageMediaKind
    public let url: URL

    public init(kind: ChatMessageMediaKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}
