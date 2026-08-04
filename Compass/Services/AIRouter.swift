import Foundation

@MainActor
final class AIRouter {
    enum Pipeline {
        case local
        case cloud
    }

    enum RequestKind {
        case completion
        case inlineQA
        case chat
        case agentic
    }

    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func pipeline(for requestKind: RequestKind = .chat) -> Pipeline {
        switch requestKind {
        case .completion, .inlineQA:
            return .local
        case .chat, .agentic:
            let isOffline = settingsStore.bool(
                forKey: "AI.OfflineModeEnabled", default: false)
            return isOffline ? .local : .cloud
        }
    }

    var usesLocalModel: Bool {
        pipeline() == .local
    }
}
