import Foundation

public struct ConversationLogEvent: Codable, Sendable {
    public let ts: String
    public let session: String
    public let conversationId: String
    public let type: String
    public let data: [String: LogValue]?
}
