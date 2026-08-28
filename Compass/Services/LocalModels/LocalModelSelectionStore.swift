import Foundation

extension Notification.Name {
    static let localModelOfflineModeDidChange = Notification.Name("LocalModelOfflineModeDidChange")
    static let remoteProviderDidChange = Notification.Name("RemoteProviderDidChange")
}

actor LocalModelSelectionStore {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        self.settingsStore = settingsStore
    }

    func isOfflineModeEnabled() -> Bool {
        settingsStore.bool(forKey: LocalModelSettingsKeys.offlineModeEnabled, default: false)
    }

    func setOfflineModeEnabled(_ enabled: Bool) {
        guard isOfflineModeEnabled() != enabled else { return }
        settingsStore.set(enabled, forKey: LocalModelSettingsKeys.offlineModeEnabled)
        NotificationCenter.default.post(
            name: .localModelOfflineModeDidChange,
            object: nil,
            userInfo: ["enabled": enabled]
        )
    }

    /// Qwen3.5 supports quantized attention KV. 4-bit is now the permanent
    /// policy (was a settings toggle, now removed from UI). The old UserDefaults
    /// value is ignored and `setKVCache4BitEnabled` is a no-op for backward compat.
    func isKVCache4BitEnabled() -> Bool { true }

    func setKVCache4BitEnabled(_ enabled: Bool) {
        // No-op — 4-bit is permanent. Keep the UserDefaults write for
        // backward compat so an old `false` does not stick if we ever revert.
        settingsStore.set(true, forKey: LocalModelSettingsKeys.kvCache4BitEnabled)
    }

    func contextLength() -> Int? {
        let val = settingsStore.integer(forKey: LocalModelSettingsKeys.contextLength)
        return val > 0 ? val : nil
    }

    func setContextLength(_ length: Int?) {
        if let length {
            settingsStore.set(length, forKey: LocalModelSettingsKeys.contextLength)
        } else {
            settingsStore.removeObject(forKey: LocalModelSettingsKeys.contextLength)
        }
    }
}
