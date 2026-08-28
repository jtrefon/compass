import Foundation

public struct ExecutionLogEvent: Codable, Sendable {
    public let ts: String
    public let session: String
    public let conversationId: String?
    public let tool: String
    public let toolCallId: String
    public let type: String
    public let data: [String: LogValue]

    public init(
        header: ExecutionLogEventHeader,
        toolCallId: String,
        type: String,
        data: [String: LogValue] = [:]
    ) {
        self.ts = header.ts
        self.session = header.session
        self.conversationId = header.conversationId
        self.tool = header.tool
        self.toolCallId = toolCallId
        self.type = type
        self.data = data
    }
}
