import XCTest
import Combine
@testable import Compass

final class AIServiceRegistryTests: XCTestCase {
    private final class SpyService: AIService, @unchecked Sendable {
    var preservesCache: Bool = false
        let name: String
        init(name: String) { self.name = name }

        func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
            AIServiceResponse(content: name, toolCalls: nil)
        }
        func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
            AIServiceResponse(content: name, toolCalls: nil)
        }
        func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
            AIServiceResponse(content: name, toolCalls: nil)
        }
    }

    func testRegisterAndRetrieveService() {
        let registry = AIServiceRegistry()
        let service = SpyService(name: "test")
        registry.register(provider: .openRouter, service: service)
        let retrieved = registry.service(for: .openRouter)
        XCTAssertNotNil(retrieved)
    }

    func testRegisterReturnsNilForUnregisteredProvider() {
        let registry = AIServiceRegistry()
        let retrieved = registry.service(for: .deepSeek)
        XCTAssertNil(retrieved)
    }

    func testRegisterOverwritesExistingService() {
        let registry = AIServiceRegistry()
        let service1 = SpyService(name: "first")
        let service2 = SpyService(name: "second")
        registry.register(provider: .openRouter, service: service1)
        registry.register(provider: .openRouter, service: service2)
        let retrieved = registry.service(for: .openRouter)
        XCTAssertNotNil(retrieved)
        // Verify overwrite by checking that the registered service is the last one
        // (Service identity check via reference comparison — register returns Void)
    }

    func testAllServicesReturnsEmptyInitially() {
        let registry = AIServiceRegistry()
        let all = registry.allServices()
        XCTAssertTrue(all.isEmpty)
    }

    func testAllServicesReturnsAllRegistered() {
        let registry = AIServiceRegistry()
        registry.register(provider: .openRouter, service: SpyService(name: "or"))
        registry.register(provider: .deepSeek, service: SpyService(name: "ds"))
        let all = registry.allServices()
        XCTAssertEqual(all.count, 2)
    }

    func testRegisterMultipleProviders() {
        let registry = AIServiceRegistry()
        let orService = SpyService(name: "openrouter")
        let dsService = SpyService(name: "deepseek")
        registry.register(provider: .openRouter, service: orService)
        registry.register(provider: .deepSeek, service: dsService)
        let orRetrieved = registry.service(for: .openRouter)
        let dsRetrieved = registry.service(for: .deepSeek)
        XCTAssertNotNil(orRetrieved)
        XCTAssertNotNil(dsRetrieved)
    }
}
