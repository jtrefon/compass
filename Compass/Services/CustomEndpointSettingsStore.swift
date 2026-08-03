import Foundation

/// Settings for a user-configured OpenAI-compatible server (local or remote).
/// The API key is intentionally optional — many self-hosted setups (e.g.
/// llama.cpp with no `--api-key`) require no authentication.
final class CustomEndpointSettingsStore: ProviderOpenRouterSettingsStore, @unchecked Sendable {
    override init(settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)) {
        super.init(
            settingsStore: settingsStore,
            keys: Keys(
                apiKey: "CustomEndpointAPIKey",
                model: "CustomEndpointModel",
                baseURL: "CustomEndpointBaseURL",
                systemPrompt: "CustomEndpointSystemPrompt",
                reasoningMode: "CustomEndpointReasoningMode",
                toolPromptMode: "CustomEndpointToolPromptMode",
                contextOverride: "CustomEndpointContextOverride"
            ),
            harnessKeys: HarnessKeys(
                apiKeyTestRunner: "TEST_RUNNER_ENV_HARNESS_CUSTOM_ENDPOINT_API_KEY",
                apiKeyFallback: "HARNESS_CUSTOM_ENDPOINT_API_KEY",
                modelTestRunner: "TEST_RUNNER_ENV_HARNESS_CUSTOM_ENDPOINT_MODEL_ID",
                modelFallback: "HARNESS_CUSTOM_ENDPOINT_MODEL_ID",
                baseURLTestRunner: "TEST_RUNNER_ENV_HARNESS_CUSTOM_ENDPOINT_BASE_URL",
                baseURLFallback: "HARNESS_CUSTOM_ENDPOINT_BASE_URL"
            ),
            defaultModel: "",
            defaultBaseURL: "http://localhost:8080/v1",
            defaultReasoningMode: .none,
            defaultToolPromptMode: .fullStatic
        )
    }
}
