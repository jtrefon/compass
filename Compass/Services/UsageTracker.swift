import Foundation

actor UsageTracker {
    private var contextLengthByModelId: [String: Int] = [:]
    private var pricingByModelId: [String: OpenRouterModel.Pricing] = [:]
    private let client: OpenRouterAPIClient
    private let eventBus: EventBusProtocol

    init(client: OpenRouterAPIClient, eventBus: EventBusProtocol) {
        self.client = client
        self.eventBus = eventBus
    }

    // MARK: - Usage Normalization

    func normalizeUsage(_ usage: OpenRouterChatUsage) -> (promptTokens: Int, completionTokens: Int, totalTokens: Int)? {
        let promptTokens = usage.promptTokens ?? usage.inputTokens
        let completionTokens = usage.completionTokens ?? usage.outputTokens
        let totalTokens = usage.totalTokens ?? {
            guard let input = usage.inputTokens, let output = usage.outputTokens else { return nil }
            return input + output
        }()
        guard let promptTokens, let completionTokens, let totalTokens else { return nil }
        return (promptTokens, completionTokens, totalTokens)
    }

    func resolvedCostMicrodollars(usage: OpenRouterChatUsage, fallback: Int?, providerName: String) -> Int? {
        if let costMicrodollars = usage.costMicrodollars { return costMicrodollars }
        if providerName == "Kilo Code", let upstreamCost = usage.costDetails?.upstreamInferenceCost {
            return microdollars(fromDollarAmount: upstreamCost)
        }
        if let directCost = usage.cost { return microdollars(fromDollarAmount: directCost) }
        return fallback
    }

    // MARK: - Cost Estimation

    func estimateCostMicrodollars(modelId: String, promptTokens: Int, completionTokens: Int, apiKey: String, baseURL: String) async throws -> Int? {
        let pricing = try await fetchPricing(modelId: modelId, apiKey: apiKey, baseURL: baseURL)
        guard let pricing else { return nil }
        let promptPricePerToken = decimalPrice(from: pricing.prompt)
        let completionPricePerToken = decimalPrice(from: pricing.completion)
        guard promptPricePerToken != 0 || completionPricePerToken != 0 else { return 0 }
        let estimatedCostDollars = (promptPricePerToken * Decimal(promptTokens)) + (completionPricePerToken * Decimal(completionTokens))
        let estimatedCostMicrodollars = estimatedCostDollars * Decimal(1_000_000)
        return NSDecimalNumber(decimal: estimatedCostMicrodollars).intValue
    }

    // MARK: - Pricing & Model Cache

    func fetchPricing(modelId: String, apiKey: String, baseURL: String) async throws -> OpenRouterModel.Pricing? {
        if let cached = pricingByModelId[modelId] { return cached }
        let context = OpenRouterAPIClient.RequestContext(baseURL: baseURL, appName: "OSX IDE", referer: "")
        let models = try await client.fetchModels(apiKey: apiKey, context: context)
        guard let model = models.first(where: { $0.id == modelId }) else { return nil }
        if let contextLength = model.contextLength {
            contextLengthByModelId[modelId] = contextLength
            ModelContextRegistry.shared.setContextLength(contextLength, for: modelId)
        }
        if let pricing = model.pricing { pricingByModelId[modelId] = pricing }
        return model.pricing
    }

    func fetchContextLength(modelId: String, apiKey: String, baseURL: String) async throws -> Int? {
        if let cached = contextLengthByModelId[modelId] { return cached }
        let context = OpenRouterAPIClient.RequestContext(baseURL: baseURL, appName: "OSX IDE", referer: "")
        let models = try await client.fetchModels(apiKey: apiKey, context: context)
        guard let model = models.first(where: { $0.id == modelId }) else { return nil }
        if let contextLength = model.contextLength {
            contextLengthByModelId[modelId] = contextLength
            ModelContextRegistry.shared.setContextLength(contextLength, for: modelId)
        }
        if let pricing = model.pricing { pricingByModelId[modelId] = pricing }
        return model.contextLength
    }

    // MARK: - Balance

    func fetchAccountBalanceIfAvailable(apiKey: String, baseURL: String, providerName: String) async throws -> Int? {
        if providerName == "Kilo Code" || baseURL.contains("api.kilo.ai") {
            guard let apiBaseURL = kiloAPIBaseURL(from: baseURL) else { return nil }
            guard let balance = try await client.fetchKiloBalance(apiKey: apiKey, apiBaseURL: apiBaseURL) else { return nil }
            return microdollars(fromDollarAmount: balance)
        }
        if providerName == "DeepSeek" || baseURL.contains("api.deepseek.com") {
            guard let apiBaseURL = providerAPIBaseURL(from: baseURL) else { return nil }
            guard let balance = try await client.fetchDeepSeekBalance(apiKey: apiKey, apiBaseURL: apiBaseURL) else { return nil }
            return microdollars(fromDollarAmount: balance)
        }
        return nil
    }

    // MARK: - Publish

    func publishUsageUpdate(usage: OpenRouterChatUsage, modelId: String, apiKey: String, baseURL: String, providerName: String, runId: String?) async throws {
        guard let normalizedUsage = normalizeUsage(usage) else { return }
        let estimatedCostMicrodollars = try? await estimateCostMicrodollars(modelId: modelId, promptTokens: normalizedUsage.promptTokens, completionTokens: normalizedUsage.completionTokens, apiKey: apiKey, baseURL: baseURL)
        let costMicrodollars = resolvedCostMicrodollars(usage: usage, fallback: estimatedCostMicrodollars, providerName: providerName)
        let accountBalanceMicrodollars = try? await fetchAccountBalanceIfAvailable(apiKey: apiKey, baseURL: baseURL, providerName: providerName)

        if let accountBalanceMicrodollars {
            await MainActor.run {
                eventBus.publish(RemoteAIAccountBalanceUpdatedEvent(providerName: providerName, modelId: modelId, runId: runId, accountBalanceMicrodollars: accountBalanceMicrodollars))
            }
        }

        let contextLength = try? await fetchContextLength(modelId: modelId, apiKey: apiKey, baseURL: baseURL)
        let event = OpenRouterUsageUpdatedEvent(
            providerName: providerName,
            modelId: modelId,
            runId: runId,
            usage: OpenRouterUsageUpdatedEvent.Usage(
                promptTokens: normalizedUsage.promptTokens,
                completionTokens: normalizedUsage.completionTokens,
                totalTokens: normalizedUsage.totalTokens,
                costMicrodollars: costMicrodollars,
                accountBalanceMicrodollars: accountBalanceMicrodollars
            ),
            contextLength: contextLength
        )
        await MainActor.run { eventBus.publish(event) }
    }

    // MARK: - Refresh Balance

    func refreshAccountBalance(apiKey: String, baseURL: String, providerName: String, model: String, runId: String?) async {
        guard !apiKey.isEmpty else { return }
        guard let balance = try? await fetchAccountBalanceIfAvailable(apiKey: apiKey, baseURL: baseURL, providerName: providerName) else { return }
        await MainActor.run {
            eventBus.publish(RemoteAIAccountBalanceUpdatedEvent(providerName: providerName, modelId: model, runId: runId, accountBalanceMicrodollars: balance))
        }
    }

    // MARK: - Helpers

    private func decimalPrice(from value: String?) -> Decimal {
        guard let value, let decimal = Decimal(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return decimal
    }

    private func microdollars(fromDollarAmount amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * Decimal(1_000_000)).intValue
    }

    private func providerAPIBaseURL(from baseURL: String) -> String? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func kiloAPIBaseURL(from baseURL: String) -> String? {
        providerAPIBaseURL(from: baseURL)
    }
}
