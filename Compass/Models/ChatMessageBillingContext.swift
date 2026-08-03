import Foundation

public struct ChatMessageBillingContext: Codable, Sendable {
    public let requestCostMicrodollars: Int?
    public let providerName: String?
    public let modelId: String?
    public let runId: String?

    public init(
        requestCostMicrodollars: Int? = nil,
        providerName: String? = nil,
        modelId: String? = nil,
        runId: String? = nil
    ) {
        self.requestCostMicrodollars = requestCostMicrodollars
        self.providerName = providerName
        self.modelId = modelId
        self.runId = runId
    }
}
