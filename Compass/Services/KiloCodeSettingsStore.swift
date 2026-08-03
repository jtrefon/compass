import Foundation

final class KiloCodeSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    static let currentBaseURL = "https://api.kilo.ai/api/openrouter"
    private static let legacyBaseURLs = ["https://api.kilo.ai/api/gateway"]

    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "KiloCodeAPIKey",
                model: "KiloCodeModel",
                baseURL: "KiloCodeBaseURL",
                systemPrompt: "KiloCodeSystemPrompt",
                reasoningMode: "KiloCodeReasoningMode",
                toolPromptMode: "KiloCodeToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_KILOCODE_API_KEY",
                apiKeyFallback: "HARNESS_KILOCODE_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_KILOCODE_MODEL_ID",
                modelFallback: "HARNESS_KILOCODE_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_KILOCODE_BASE_URL",
                baseURLFallback: "HARNESS_KILOCODE_BASE_URL"
            ),
            defaultModel: "kilo-auto/balanced",
            defaultBaseURL: Self.currentBaseURL,
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }

    override func load(includeApiKey: Bool = true) -> OpenRouterSettings {
        var settings = super.load(includeApiKey: includeApiKey)
        settings.baseURL = resolvedBaseURL(storedValue: settings.baseURL)
        return settings
    }

    private func resolvedBaseURL(storedValue: String?) -> String {
        guard let trimmed = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return Self.currentBaseURL
        }
        if Self.legacyBaseURLs.contains(trimmed) {
            return Self.currentBaseURL
        }
        return trimmed
    }
}
