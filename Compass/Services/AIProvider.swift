import Foundation

public enum AIProviderID: String, CaseIterable, Sendable, Equatable {
    case openRouter
    case alibabaCloud
    case kiloCode
    case deepSeek
    case openCodeGo
    case openCodeGoSubscription
    case customEndpoint
    case local

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .alibabaCloud: return "Alibaba Cloud"
        case .kiloCode: return "Kilo Code"
        case .deepSeek: return "DeepSeek"
        case .openCodeGo: return "OpenCode Go"
        case .openCodeGoSubscription: return "OpenCode Go (Subscription)"
        case .customEndpoint: return "Custom Endpoint"
        case .local: return "Local Model"
        }
    }
}

public struct ProviderConfiguration: Sendable, Equatable {
    public let providerID: AIProviderID
    public let apiEndpoint: URL
    public let defaultModel: String
    public let supportsNativeReasoning: Bool
    public let requiresReasoningEcho: Bool
    public let maxOutputTokens: Int

    public init(
        providerID: AIProviderID,
        apiEndpoint: URL,
        defaultModel: String,
        supportsNativeReasoning: Bool = true,
        requiresReasoningEcho: Bool = false,
        maxOutputTokens: Int = 4096
    ) {
        self.providerID = providerID
        self.apiEndpoint = apiEndpoint
        self.defaultModel = defaultModel
        self.supportsNativeReasoning = supportsNativeReasoning
        self.requiresReasoningEcho = requiresReasoningEcho
        self.maxOutputTokens = maxOutputTokens
    }
}
