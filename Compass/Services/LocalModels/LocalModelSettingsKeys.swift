import Foundation

/// Single source of truth for local-model storage keys. Never spread raw
/// string literals across stores, view models, and panels.
enum LocalModelSettingsKeys {
    static let offlineModeEnabled = "AI.OfflineModeEnabled"
    static let kvCache4BitEnabled = "LocalModel.KVCache4BitEnabled"
    static let contextLength = "LocalModel.ContextLength"
    static let reasoningIntensity = "AI.ReasoningIntensity"
}
