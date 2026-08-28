import Foundation

public struct ConversationIndexEntry: Codable, Sendable {
    public let ts: String
    public let session: String
    public let conversationId: String
    public let mode: String
    public let projectRoot: String?
}
