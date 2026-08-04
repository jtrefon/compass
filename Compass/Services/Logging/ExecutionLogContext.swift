import Foundation

public struct ExecutionLogContext: Sendable {
    public let conversationId: String?
    public let tool: String

    public init(conversationId: String?, tool: String) {
        self.conversationId = conversationId
        self.tool = tool
    }
}
