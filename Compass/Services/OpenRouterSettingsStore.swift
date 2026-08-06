import Foundation

protocol OpenRouterSettingsLoading: Sendable {
    func load(includeApiKey: Bool) -> OpenRouterSettings
}

protocol OpenRouterSettingsStoring: OpenRouterSettingsLoading {
    func save(_ settings: OpenRouterSettings)
}

class ProviderOpenRouterSettingsStore: OpenRouterSettingsStoring, @unchecked Sendable {
    struct Keys {
        let apiKey: String
        let model: String
        let baseURL: String
        let systemPrompt: String
        let reasoningMode: String
        let toolPromptMode: String
        var contextOverride: String = ""
    }

    struct HarnessKeys {
        let apiKeyTestRunner: String
        let apiKeyFallback: String
        let modelTestRunner: String
        let modelFallback: String
        let baseURLTestRunner: String
        let baseURLFallback: String
    }

    let settingsStore: SettingsStore
    let environment: [String: String]
    private let keys: Keys
    private let harnessKeys: HarnessKeys
    private let defaultModel: String
    private let defaultBaseURL: String
    private let defaultReasoningMode: ReasoningMode
    private let defaultToolPromptMode: ToolPromptMode

    init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        self.settingsStore = settingsStore
        self.environment = ProcessInfo.processInfo.environment
        self.keys = Keys(
            apiKey: "",
            model: "",
            baseURL: "",
            systemPrompt: "",
            reasoningMode: "",
            toolPromptMode: "",
            contextOverride: ""
        )
        self.harnessKeys = HarnessKeys(
            apiKeyTestRunner: "",
            apiKeyFallback: "",
            modelTestRunner: "",
            modelFallback: "",
            baseURLTestRunner: "",
            baseURLFallback: ""
        )
        self.defaultModel = ""
        self.defaultBaseURL = OpenRouterSettings.empty.baseURL
        self.defaultReasoningMode = .modelAndAgent
        self.defaultToolPromptMode = .concise
    }

    init(
        settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults),
        keys: Keys,
        harnessKeys: HarnessKeys,
        defaultModel: String,
        defaultBaseURL: String,
        defaultReasoningMode: ReasoningMode = .modelAndAgent,
        defaultToolPromptMode: ToolPromptMode = .concise
    ) {
        self.settingsStore = settingsStore
        self.environment = ProcessInfo.processInfo.environment
        self.keys = keys
        self.harnessKeys = harnessKeys
        self.defaultModel = defaultModel
        self.defaultBaseURL = defaultBaseURL
        self.defaultReasoningMode = defaultReasoningMode
        self.defaultToolPromptMode = defaultToolPromptMode
    }

    func load(includeApiKey: Bool = true) -> OpenRouterSettings {
        let apiKey: String
        if includeApiKey {
            apiKey = harnessOverrideValue(
                testRunnerKey: harnessKeys.apiKeyTestRunner,
                fallbackKey: harnessKeys.apiKeyFallback,
                defaultValue: Self.loadApiKey(
                    userDefaultsKey: keys.apiKey,
                    settingsStore: settingsStore
                )
            )
        } else {
            apiKey = ""
        }

        let model = harnessOverrideValue(
            testRunnerKey: harnessKeys.modelTestRunner,
            fallbackKey: harnessKeys.modelFallback,
            defaultValue: settingsStore.string(forKey: keys.model) ?? defaultModel
        )
        let baseURL = harnessOverrideValue(
            testRunnerKey: harnessKeys.baseURLTestRunner,
            fallbackKey: harnessKeys.baseURLFallback,
            defaultValue: settingsStore.string(forKey: keys.baseURL) ?? defaultBaseURL
        )

        return OpenRouterSettings(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            systemPrompt: settingsStore.string(forKey: keys.systemPrompt) ?? "",
            reasoningMode: loadReasoningMode(),
            toolPromptMode: loadToolPromptMode(),
            contextOverride: settingsStore.integer(forKey: keys.contextOverride)
        )
    }

    func save(_ settings: OpenRouterSettings) {
        settingsStore.set(settings.model, forKey: keys.model)
        settingsStore.set(settings.baseURL, forKey: keys.baseURL)
        settingsStore.set(settings.systemPrompt, forKey: keys.systemPrompt)
        settingsStore.set(settings.reasoningMode.rawValue, forKey: keys.reasoningMode)
        settingsStore.set(settings.toolPromptMode.rawValue, forKey: keys.toolPromptMode)
        if settings.contextOverride > 0 {
            settingsStore.set(settings.contextOverride, forKey: keys.contextOverride)
        }
        // API keys live in plaintext UserDefaults. The Keychain-backed store
        // (SecureValueStore) was REMOVED: macOS prompts for the keychain
        // password on every launch/test from an ad-hoc-signed app, which made
        // the app unusable and timed out CI. Plaintext defaults is the
        // documented trade-off (local machine, user-owned).
        settingsStore.set(settings.apiKey, forKey: keys.apiKey)
    }

    /// Loads a provider API key from UserDefaults. (The Keychain path was
    /// removed — see `save(_:)`.)
    static func loadApiKey(userDefaultsKey: String, settingsStore: SettingsStore) -> String {
        settingsStore.string(forKey: userDefaultsKey) ?? ""
    }

    func loadReasoningMode() -> ReasoningMode {
        ReasoningMode(
            rawValue: settingsStore.string(forKey: keys.reasoningMode) ?? ""
        ) ?? defaultReasoningMode
    }

    private func loadToolPromptMode() -> ToolPromptMode {
        ToolPromptMode(
            rawValue: settingsStore.string(forKey: keys.toolPromptMode) ?? ""
        ) ?? defaultToolPromptMode
    }

    func harnessOverrideValue(
        testRunnerKey: String,
        fallbackKey: String,
        defaultValue: String
    ) -> String {
        if let value = environment[testRunnerKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = environment[fallbackKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return defaultValue
    }
}

final class OpenRouterSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    private let reasoningEnabledKey = "OpenRouterReasoningEnabled"

    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "OpenRouterAPIKey",
                model: "OpenRouterModel",
                baseURL: "OpenRouterBaseURL",
                systemPrompt: "OpenRouterSystemPrompt",
                reasoningMode: "OpenRouterReasoningMode",
                toolPromptMode: "OpenRouterToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENROUTER_API_KEY",
                apiKeyFallback: "HARNESS_OPENROUTER_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_MODEL_ID",
                modelFallback: "HARNESS_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENROUTER_BASE_URL",
                baseURLFallback: "HARNESS_OPENROUTER_BASE_URL"
            ),
            defaultModel: "",
            defaultBaseURL: OpenRouterSettings.empty.baseURL,
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }

    override func save(_ settings: OpenRouterSettings) {
        super.save(settings)
        settingsStore.set(settings.reasoningMode.includesAgentReasoning, forKey: reasoningEnabledKey)
    }

    override func loadReasoningMode() -> ReasoningMode {
        if let storedMode = settingsStore.string(forKey: "OpenRouterReasoningMode"),
           let reasoningMode = ReasoningMode(rawValue: storedMode) {
            return reasoningMode
        }

        let legacyReasoningEnabled = settingsStore.bool(forKey: reasoningEnabledKey, default: true)
        return legacyReasoningEnabled ? .modelAndAgent : .none
    }
}
