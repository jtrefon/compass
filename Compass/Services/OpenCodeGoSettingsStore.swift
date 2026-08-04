import Foundation

final class OpenCodeGoSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "OpenCodeGoApiKey",
                model: "OpenCodeGoModel",
                baseURL: "OpenCodeGoBaseURL",
                systemPrompt: "OpenCodeGoSystemPrompt",
                reasoningMode: "OpenCodeGoReasoningMode",
                toolPromptMode: "OpenCodeGoToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_API_KEY",
                apiKeyFallback: "HARNESS_OPENCODEGO_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_MODEL_ID",
                modelFallback: "HARNESS_OPENCODEGO_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_BASE_URL",
                baseURLFallback: "HARNESS_OPENCODEGO_BASE_URL"
            ),
            defaultModel: "deepseek-v4-flash",
            defaultBaseURL: "https://opencode.ai/zen/go/v1",
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }
}
