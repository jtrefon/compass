import Foundation

public struct AIServiceResponse: Sendable {
    public let content: String?
    public let toolCalls: [AIToolCall]?
    public let reasoning: String?
    /// Tool calls whose arguments failed to parse. The caller must surface these
    /// as failed tool results so the model can self-correct instead of the engine
    /// dispatching a call with corrupted/missing arguments.
    public let malformedToolCalls: [MalformedToolCall]?

    public init(
        content: String?,
        toolCalls: [AIToolCall]?,
        reasoning: String? = nil,
        malformedToolCalls: [MalformedToolCall]? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.malformedToolCalls = malformedToolCalls
    }
}
