import Foundation

public struct ChatMessageToolContext: Sendable {
    public let toolName: String?
    public let toolStatus: ToolExecutionStatus?
    public let target: ToolInvocationTarget
    public let toolCalls: [AIToolCall]

    public init(
        toolName: String? = nil,
        toolStatus: ToolExecutionStatus? = nil,
        target: ToolInvocationTarget = ToolInvocationTarget(),
        toolCalls: [AIToolCall] = []
    ) {
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolCalls = toolCalls
        self.target = target
    }

    public var targetFile: String? {
        target.targetFile
    }

    public var toolCallId: String? {
        target.toolCallId
    }
}
