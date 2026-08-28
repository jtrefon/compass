import Foundation

protocol ProviderConfig: Sendable {
    var providerID: AIProviderID { get }
    var providerName: String { get }
    var supportsStreamingWithTools: Bool { get }
    var supportsNativeReasoning: Bool { get }
    var requiresReasoningEcho: Bool { get }

    func buildRequestContext(baseURL: String) -> OpenRouterAPIClient.RequestContext
    func resolvedCostMicrodollars(usage: OpenRouterChatUsage, fallback: Int?) -> Int?
    func fetchBalance(apiKey: String, baseURL: String, client: OpenRouterAPIClient) async throws -> Int?
}

extension ProviderConfig {
    func buildRequestContext(baseURL: String) -> OpenRouterAPIClient.RequestContext {
        OpenRouterAPIClient.RequestContext(baseURL: baseURL, appName: providerName, referer: "")
    }

    func resolvedCostMicrodollars(usage: OpenRouterChatUsage, fallback: Int?) -> Int? {
        usage.costMicrodollars ?? usage.cost.map { microdollars(fromDollarAmount: $0) } ?? fallback
    }

    func fetchBalance(apiKey: String, baseURL: String, client: OpenRouterAPIClient) async throws -> Int? {
        nil
    }

    private func microdollars(fromDollarAmount amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * Decimal(1_000_000)).intValue
    }
}
