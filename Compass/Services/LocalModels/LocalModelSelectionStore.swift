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

    /// KV cache quantization toggle (4-bit vs FP16). Defaults to FP16: the
    /// 4-bit path forces non-fused quantized attention (no flash attention),
    /// which materializes a full attention score matrix during prefill — a
    /// 4–8 GB transient spike that exceeds the resident KV savings on 16 GB
    /// machines. FP16 enables `MLXFast.scaledDotProductAttention` (fused flash
    /// attention): lower decode latency, no score matrix materialization, and
    /// a lower transient peak despite the larger resident KV cache. Users on
    /// 32+ GB machines may opt into 4-bit for longer contexts where the
    /// resident savings outweigh the transient cost. A flip invalidates the
    /// in-memory cachePolicy (`q4=` in the key) and the disk prefix hash
    /// (`kv4=`), so the next generation re-prefills in the new format — no
    /// stale-format reuse.
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
