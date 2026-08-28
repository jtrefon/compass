import Foundation

final class OpenCodeGoSubscriptionSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "OpenCodeGoSubscriptionApiKey",
                model: "OpenCodeGoSubscriptionModel",
                baseURL: "OpenCodeGoSubscriptionBaseURL",
                systemPrompt: "OpenCodeGoSubscriptionSystemPrompt",
                reasoningMode: "OpenCodeGoSubscriptionReasoningMode",
                toolPromptMode: "OpenCodeGoSubscriptionToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_SUB_API_KEY",
                apiKeyFallback: "HARNESS_OPENCODEGO_SUB_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_SUB_MODEL_ID",
                modelFallback: "HARNESS_OPENCODEGO_SUB_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_OPENCODEGO_SUB_BASE_URL",
                baseURLFallback: "HARNESS_OPENCODEGO_SUB_BASE_URL"
            ),
            defaultModel: "deepseek-v4-flash",
            defaultBaseURL: "https://opencode.ai/zen/sub/v1",
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }
}
