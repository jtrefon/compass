import XCTest
@testable import Compass

final class ProviderConfigurationsTests: XCTestCase {
    func testOpenRouterProviderConfig() {
        let config = OpenRouterProviderConfig()
        XCTAssertEqual(config.providerID, .openRouter)
        XCTAssertEqual(config.providerName, "OpenRouter")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertTrue(config.supportsNativeReasoning)
        XCTAssertFalse(config.requiresReasoningEcho)
    }

    func testAlibabaProviderConfig() {
        let config = AlibabaProviderConfig()
        XCTAssertEqual(config.providerID, .alibabaCloud)
        XCTAssertEqual(config.providerName, "Alibaba Cloud")
        XCTAssertFalse(config.supportsStreamingWithTools)
        XCTAssertFalse(config.supportsNativeReasoning)
    }

    func testDeepSeekProviderConfig() {
        let config = DeepSeekProviderConfig()
        XCTAssertEqual(config.providerID, .deepSeek)
        XCTAssertEqual(config.providerName, "DeepSeek")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertTrue(config.supportsNativeReasoning)
        XCTAssertTrue(config.requiresReasoningEcho)
    }

    func testKiloCodeProviderConfig() {
        let config = KiloCodeProviderConfig()
        XCTAssertEqual(config.providerID, .kiloCode)
        XCTAssertEqual(config.providerName, "Kilo Code")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertTrue(config.supportsNativeReasoning)
        XCTAssertFalse(config.requiresReasoningEcho)

        let context = config.buildRequestContext(baseURL: "https://api.kilo.ai/api/openrouter")
        XCTAssertEqual(context.appName, "Kilo Code")
        XCTAssertEqual(context.referer, "https://kilocode.ai")
    }

    func testOpenCodeGoProviderConfig() {
        let config = OpenCodeGoProviderConfig()
        XCTAssertEqual(config.providerID, .openCodeGo)
        XCTAssertEqual(config.providerName, "OpenCode Go")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertTrue(config.supportsNativeReasoning)
    }

    func testOpenCodeGoSubscriptionProviderConfig() {
        let config = OpenCodeGoSubscriptionProviderConfig()
        XCTAssertEqual(config.providerID, .openCodeGoSubscription)
        XCTAssertEqual(config.providerName, "OpenCode Go (Subscription)")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertTrue(config.supportsNativeReasoning)
        XCTAssertFalse(config.requiresReasoningEcho)
    }

    func testCustomEndpointProviderConfig() {
        let config = CustomEndpointProviderConfig()
        XCTAssertEqual(config.providerID, .customEndpoint)
        XCTAssertEqual(config.providerName, "Custom Endpoint")
        XCTAssertTrue(config.supportsStreamingWithTools)
        XCTAssertFalse(config.supportsNativeReasoning)
        XCTAssertFalse(config.requiresReasoningEcho)
    }

    func testProviderConfigurationBuilder() {
        let url = URL(string: "https://api.test.com/v1")!
        let config = ProviderConfiguration(
            providerID: .openRouter,
            apiEndpoint: url,
            defaultModel: "test-model"
        )
        XCTAssertEqual(config.providerID, .openRouter)
        XCTAssertEqual(config.apiEndpoint, url)
        XCTAssertEqual(config.defaultModel, "test-model")
    }

    func testRemoteAIProviderToAIProviderID() {
        XCTAssertEqual(RemoteAIProvider.openRouter.toAIProviderID, .openRouter)
        XCTAssertEqual(RemoteAIProvider.alibabaCloud.toAIProviderID, .alibabaCloud)
        XCTAssertEqual(RemoteAIProvider.kiloCode.toAIProviderID, .kiloCode)
        XCTAssertEqual(RemoteAIProvider.deepSeek.toAIProviderID, .deepSeek)
        XCTAssertEqual(RemoteAIProvider.openCodeGo.toAIProviderID, .openCodeGo)
        XCTAssertEqual(RemoteAIProvider.openCodeGoSubscription.toAIProviderID, .openCodeGoSubscription)
        XCTAssertEqual(RemoteAIProvider.customEndpoint.toAIProviderID, .customEndpoint)
    }

    func testAIProviderIDAllCasesCoverage() {
        let allCases = AIProviderID.allCases
        XCTAssertTrue(allCases.contains(.openRouter))
        XCTAssertTrue(allCases.contains(.alibabaCloud))
        XCTAssertTrue(allCases.contains(.kiloCode))
        XCTAssertTrue(allCases.contains(.deepSeek))
        XCTAssertTrue(allCases.contains(.openCodeGo))
        XCTAssertTrue(allCases.contains(.openCodeGoSubscription))
        XCTAssertTrue(allCases.contains(.customEndpoint))
        XCTAssertTrue(allCases.contains(.local))
    }
}
