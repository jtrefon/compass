import Foundation

@MainActor
class InlineCompletionSettingsStore {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        self.settingsStore = settingsStore
    }

    func load() -> InlineCompletionSettings {
        let defaults = InlineCompletionSettings.default

        let storedDebounce = Int(settingsStore.double(forKey: AppConstantsStorage.inlineCompletionDebounceMsKey))
        let storedAggressiveness = settingsStore.double(forKey: AppConstantsStorage.inlineCompletionAggressivenessKey)
        let storedMaxLength = Int(settingsStore.double(forKey: AppConstantsStorage.inlineCompletionMaxLengthKey))

        return InlineCompletionSettings(
            isEnabled: settingsStore.bool(forKey: AppConstantsStorage.inlineCompletionEnabledKey, default: defaults.isEnabled),
            debounceMilliseconds: storedDebounce == 0 ? defaults.debounceMilliseconds : max(50, min(800, storedDebounce)),
            aggressiveness: storedAggressiveness == 0 ? defaults.aggressiveness : max(0.05, min(1.0, storedAggressiveness)),
            maxSuggestionLength: storedMaxLength == 0 ? defaults.maxSuggestionLength : max(16, min(512, storedMaxLength)),
            multilineEnabled: settingsStore.bool(forKey: AppConstantsStorage.inlineCompletionMultilineEnabledKey, default: defaults.multilineEnabled),
            retrievalEnabled: settingsStore.bool(forKey: AppConstantsStorage.inlineCompletionRetrievalEnabledKey, default: defaults.retrievalEnabled),
            routingMode: InlineCompletionRoutingMode(rawValue: settingsStore.string(forKey: AppConstantsStorage.inlineCompletionRoutingModeKey) ?? "") ?? defaults.routingMode,
            debugOverlayEnabled: settingsStore.bool(forKey: AppConstantsStorage.inlineCompletionDebugOverlayKey, default: defaults.debugOverlayEnabled)
        )
    }
}
