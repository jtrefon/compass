import Foundation

public struct AIServiceMessageWithProjectRootRequest: Sendable {
    public let message: String
    public let context: String?
    public let tools: [AITool]?
    public let mode: AIMode?
    public let projectRoot: URL?

    public init(
        message: String,
        context: String?,
        tools: [AITool]?,
        mode: AIMode?,
        projectRoot: URL?
    ) {
        self.message = message
        self.context = context
        self.tools = tools
        self.mode = mode
        self.projectRoot = projectRoot
    }
}
