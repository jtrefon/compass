import Foundation

public struct OpenRouterUsageUpdatedEvent: Event {
    public struct Usage: Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        public let costMicrodollars: Int?
        public let accountBalanceMicrodollars: Int?

        public init(
            promptTokens: Int,
            completionTokens: Int,
            totalTokens: Int,
            costMicrodollars: Int? = nil,
            accountBalanceMicrodollars: Int? = nil
        ) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.costMicrodollars = costMicrodollars
            self.accountBalanceMicrodollars = accountBalanceMicrodollars
        }
    }

    public let providerName: String
    public let modelId: String
    public let runId: String?
    public let usage: Usage
    public let contextLength: Int?

    public init(
        providerName: String,
        modelId: String,
        runId: String?,
        usage: Usage,
        contextLength: Int?
    ) {
        self.providerName = providerName
        self.modelId = modelId
        self.runId = runId
        self.usage = usage
        self.contextLength = contextLength
    }
}
