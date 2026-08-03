import Foundation

public struct ChatMessageContentContext: Sendable {
    public let reasoning: String?
    public let codeContext: String?

    public init(reasoning: String? = nil, codeContext: String? = nil) {
        self.reasoning = reasoning
        self.codeContext = codeContext
    }
}
