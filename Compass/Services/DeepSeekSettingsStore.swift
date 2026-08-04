import Foundation

final class DeepSeekSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "DeepSeekAPIKey",
                model: "DeepSeekModel",
                baseURL: "DeepSeekBaseURL",
                systemPrompt: "DeepSeekSystemPrompt",
                reasoningMode: "DeepSeekReasoningMode",
                toolPromptMode: "DeepSeekToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_DEEPSEEK_API_KEY",
                apiKeyFallback: "HARNESS_DEEPSEEK_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_DEEPSEEK_MODEL_ID",
                modelFallback: "HARNESS_DEEPSEEK_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_DEEPSEEK_BASE_URL",
                baseURLFallback: "HARNESS_DEEPSEEK_BASE_URL"
            ),
            defaultModel: "deepseek-chat",
            defaultBaseURL: "https://api.deepseek.com/v1",
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }
}
