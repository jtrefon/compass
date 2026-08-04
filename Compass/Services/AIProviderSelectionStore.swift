import Foundation

enum RemoteAIProvider: String, CaseIterable, Equatable {
    case openRouter
    case alibabaCloud
    case kiloCode
    case deepSeek
    case openCodeGo
    case openCodeGoSubscription
    case customEndpoint

    var displayName: String {
        switch self {
        case .openRouter:
            return "OpenRouter"
        case .alibabaCloud:
            return "Alibaba Cloud"
        case .kiloCode:
            return "Kilo Code"
        case .deepSeek:
            return "DeepSeek"
        case .openCodeGo:
            return "OpenCode Go"
        case .openCodeGoSubscription:
            return "OpenCode Go (Subscription)"
        case .customEndpoint:
            return "Custom Endpoint"
        }
    }

    var toAIProviderID: AIProviderID {
        switch self {
        case .openRouter: return .openRouter
        case .alibabaCloud: return .alibabaCloud
        case .kiloCode: return .kiloCode
        case .deepSeek: return .deepSeek
        case .openCodeGo: return .openCodeGo
        case .openCodeGoSubscription: return .openCodeGoSubscription
        case .customEndpoint: return .customEndpoint
        }
    }
}

actor AIProviderSelectionStore {
    private let settingsStore: SettingsStore
    private let selectedRemoteProviderKey = "AI.SelectedRemoteProvider"

    init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        self.settingsStore = settingsStore
    }

    func selectedRemoteProvider() -> RemoteAIProvider {
        guard let raw = settingsStore.string(forKey: selectedRemoteProviderKey),
              let provider = RemoteAIProvider(rawValue: raw) else {
            return .openRouter
        }
        return provider
    }

    func setSelectedRemoteProvider(_ provider: RemoteAIProvider) {
        settingsStore.set(provider.rawValue, forKey: selectedRemoteProviderKey)
        NotificationCenter.default.post(name: .remoteProviderDidChange, object: nil)
    }
}
