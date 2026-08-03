import Foundation

public struct ExecutionLogAppendRequest: Sendable {
    public let context: ExecutionLogContext
    public let toolCallId: String
    public let type: String
    public let data: [String: LogValue]

    public init(
        toolCallId: String,
        type: String,
        data: [String: Any] = [:],
        context: ExecutionLogContext
    ) {
        self.context = context
        self.toolCallId = toolCallId
        self.type = type
        self.data = data.mapValues { LogValue.from($0) }
    }
}
