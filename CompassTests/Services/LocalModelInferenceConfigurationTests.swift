import XCTest

@testable import Compass

/// Context-window regression suite for the local MLX chat pipeline.
///
/// Issue: the settings slider stored a context length up to the model's
/// capability (262,144 for Qwen3.5-4B), but the inference layer clamped it to
/// 16K and capped the KV rotating window at 4K — the slider value never
/// reached MLX (and a 4K window evicted the system prompt + tool schemas,
/// killing tool calls). Resolution: the slider value passes through to the
/// resolved context up to `maxModelContextLength`, and the KV window follows
/// the context (rotating-full), with 4-bit KV still opt-in for memory.
final class LocalModelInferenceConfigurationTests: XCTestCase {

    private func resolve(
        defaultContextLength: Int = 65_536,
        defaultMaxOutputTokens: Int = 2_048,
        defaultTemperature: Float = 0.7,
        defaultTopP: Float = 0.9,
        defaultRepetitionPenalty: Float? = nil,
        defaultRepetitionContextSize: Int = 128,
        defaultKVCache4BitEnabled: Bool = false
    ) -> LocalModelInferenceConfiguration {
        LocalModelInferenceOverrides.resolve(
            defaultContextLength: defaultContextLength,
            defaultMaxOutputTokens: defaultMaxOutputTokens,
            defaultTemperature: defaultTemperature,
            defaultTopP: defaultTopP,
            defaultRepetitionPenalty: defaultRepetitionPenalty,
            defaultRepetitionContextSize: defaultRepetitionContextSize,
            defaultKVCache4BitEnabled: defaultKVCache4BitEnabled
        )
    }

    func testDefaultContextLengthPassesThrough64K() {
        let config = resolve(defaultContextLength: 65_536)
        XCTAssertEqual(config.contextLength, 65_536, "the model's default 64k must reach MLX unclamped")
    }

    func testSliderValueReachesMaxModelContext() {
        let config = resolve(defaultContextLength: 262_144)
        XCTAssertEqual(config.contextLength, 262_144, "the slider max (model capability) must pass through")
    }

    func testContextLengthClampedToModelCapability() {
        let config = resolve(defaultContextLength: 1_000_000)
        XCTAssertEqual(config.contextLength, LocalModelInferenceOverrides.maxModelContextLength)
    }

    func testContextLengthBelowCapPassesThrough() {
        let config = resolve(defaultContextLength: 4_096)
        XCTAssertEqual(config.contextLength, 4_096)
    }

    func testKVWindowFollowsContext() {
        let config = resolve(defaultContextLength: 65_536)
        XCTAssertEqual(config.maxKVSize, 65_536, "the KV window must follow the slider so tools stay resident")
        XCTAssertEqual(config.cacheKind, "rotating-full")
    }

    func testFullKVWhenWindowMatchesContext() {
        let config = resolve(defaultContextLength: 4_096)
        XCTAssertEqual(config.maxKVSize, 4_096)
        XCTAssertEqual(config.cacheKind, "rotating-full")
    }

    func testMaxKVNeverExceedsContextLength() {
        let config = resolve(defaultContextLength: 2_048)
        XCTAssertEqual(config.maxKVSize, 2_048)
    }

    func testPrefillStepSizeDefault512() {
        let config = resolve()
        XCTAssertEqual(config.prefillStepSize, 512)
    }

    func testChatModelClaimsQuantizedKVSupport() {
        XCTAssertTrue(
            LocalModelCatalog.chatModel.supportsQuantizedKVCache,
            "Qwen35TextModel.newCache now honors kvBits (QuantizedKVCache) and maxKVSize (RotatingKVCache) on the 8 full-attention layers"
        )
    }

    func testKVCache4BitOffByDefault() async {
        let suiteName = "LocalModelInferenceConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalModelSelectionStore(
            settingsStore: SettingsStore(userDefaults: defaults)
        )
        let enabled = await store.isKVCache4BitEnabled()
        XCTAssertFalse(enabled, "4-bit KV must be opt-in, not the default")
    }

    func testChatModelExposes262KCapability() {
        XCTAssertEqual(LocalModelCatalog.chatModel.maxContextLength, 262_144)
    }
}
