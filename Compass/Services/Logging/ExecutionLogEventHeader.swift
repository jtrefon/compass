import Foundation

public struct ExecutionLogEventHeader: Sendable {
    public let ts: String
    public let session: String
    public let conversationId: String?
    public let tool: String

    public init(ts: String, session: String, conversationId: String?, tool: String) {
        self.ts = ts
        self.session = session
        self.conversationId = conversationId
        self.tool = tool
    }
}
