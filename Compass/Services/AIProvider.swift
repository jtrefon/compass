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
