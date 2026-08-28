import Foundation

final class AlibabaSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "AlibabaApiKey",
                model: "AlibabaModel",
                baseURL: "AlibabaBaseURL",
                systemPrompt: "AlibabaSystemPrompt",
                reasoningMode: "AlibabaReasoningMode",
                toolPromptMode: "AlibabaToolPromptMode"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_ALIBABA_API_KEY",
                apiKeyFallback: "HARNESS_ALIBABA_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_ALIBABA_MODEL_ID",
                modelFallback: "HARNESS_ALIBABA_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_ALIBABA_BASE_URL",
                baseURLFallback: "HARNESS_ALIBABA_BASE_URL"
            ),
            defaultModel: "qwen-plus",
            defaultBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            defaultReasoningMode: .modelAndAgent,
            defaultToolPromptMode: .fullStatic
        )
    }
}
