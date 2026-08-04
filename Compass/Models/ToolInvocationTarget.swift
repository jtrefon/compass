import Foundation

public struct ToolInvocationTarget: Sendable {
    public let targetFile: String?
    public let toolCallId: String?

    public init(targetFile: String? = nil, toolCallId: String? = nil) {
        self.targetFile = targetFile
        self.toolCallId = toolCallId
    }
}
