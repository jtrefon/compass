import Foundation

extension Notification.Name {
    static let localModelOfflineModeDidChange = Notification.Name("LocalModelOfflineModeDidChange")
    static let localModelSelectionDidChange = Notification.Name("LocalModelSelectionDidChange")
    static let remoteProviderDidChange = Notification.Name("RemoteProviderDidChange")
}

actor LocalModelSelectionStore {
    private let settingsStore: SettingsStore
    private let selectedModelKey = "LocalModel.SelectedId"
    private let offlineModeEnabledKey = "AI.OfflineModeEnabled"
    private let kvCache4BitEnabledKey = "LocalModel.KVCache4BitEnabled"
    private let contextLengthKey = "LocalModel.ContextLength"

    init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        self.settingsStore = settingsStore
    }

    func selectedModelId() -> String {
        (settingsStore.string(forKey: selectedModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setSelectedModelId(_ modelId: String) {
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModelId() != trimmedModelId else { return }
        settingsStore.set(trimmedModelId, forKey: selectedModelKey)
        NotificationCenter.default.post(
            name: .localModelSelectionDidChange,
            object: nil,
            userInfo: ["modelId": trimmedModelId]
        )
    }

    func isOfflineModeEnabled() -> Bool {
        settingsStore.bool(forKey: offlineModeEnabledKey, default: false)
    }

    func setOfflineModeEnabled(_ enabled: Bool) {
        guard isOfflineModeEnabled() != enabled else { return }
        settingsStore.set(enabled, forKey: offlineModeEnabledKey)
        NotificationCenter.default.post(
            name: .localModelOfflineModeDidChange,
            object: nil,
            userInfo: ["enabled": enabled]
        )
    }

    func isKVCache4BitEnabled() -> Bool {
        settingsStore.bool(forKey: kvCache4BitEnabledKey, default: true)
    }

    func setKVCache4BitEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: kvCache4BitEnabledKey)
    }

    func contextLength() -> Int? {
        let val = settingsStore.integer(forKey: contextLengthKey)
        return val > 0 ? val : nil
    }

    func setContextLength(_ length: Int?) {
        if let length {
            settingsStore.set(length, forKey: contextLengthKey)
        } else {
            settingsStore.removeObject(forKey: contextLengthKey)
        }
    }
}
