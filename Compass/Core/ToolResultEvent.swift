import Foundation

/// Structured event for tool execution results.
/// Carries structured input/output so subscribers (LogCoordinator, EmbeddingCoordinator)
/// can process without parsing unstructured text.
public struct ToolResultEvent: Event, Sendable {
    public let conversationId: String?
    public let toolCallId: String
    public let toolName: String
    public let type: String
    public let input: String?
    public let output: String?
    public let duration: TimeInterval?
    public let metadata: [String: String]

    public init(
        conversationId: String?,
        toolCallId: String,
        toolName: String,
        type: String,
        input: String? = nil,
        output: String? = nil,
        duration: TimeInterval? = nil,
        metadata: [String: String] = [:]
    ) {
        self.conversationId = conversationId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.type = type
        self.input = input
        self.output = output
        self.duration = duration
        self.metadata = metadata
    }
}
