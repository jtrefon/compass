import Foundation

public struct RemoteAIAccountBalanceUpdatedEvent: Event {
    public let providerName: String
    public let modelId: String
    public let runId: String?
    public let accountBalanceMicrodollars: Int

    public init(
        providerName: String,
        modelId: String,
        runId: String?,
        accountBalanceMicrodollars: Int
    ) {
        self.providerName = providerName
        self.modelId = modelId
        self.runId = runId
        self.accountBalanceMicrodollars = accountBalanceMicrodollars
    }
}
