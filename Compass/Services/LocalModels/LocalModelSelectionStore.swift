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

    /// Honest default: the fixed chat model does NOT support a quantized KV
    /// combiner, so 4-bit KV would be silently ignored. Only explicit opt-in
    /// (or the env knob in the benchmark harness) enables it.
    func isKVCache4BitEnabled() -> Bool {
        settingsStore.bool(forKey: LocalModelSettingsKeys.kvCache4BitEnabled, default: false)
    }

    func setKVCache4BitEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: LocalModelSettingsKeys.kvCache4BitEnabled)
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
