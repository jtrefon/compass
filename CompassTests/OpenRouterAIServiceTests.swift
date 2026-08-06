import XCTest
import Combine

@testable import Compass

final class OpenRouterAIServiceTests: XCTestCase {
    private final class NoOpEventBus: EventBusProtocol, @unchecked Sendable {
        func publish<E>(_ event: E) where E : Event {
            // No-op
        }

        func subscribe<E>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable where E : Event {
            AnyCancellable {}
        }
    }

    func testDecodeOpenRouterErrorMessageIncludesProviderNameSuffix() async throws {
        let json = """
        {
          "error": {
            "message": "Rate limit exceeded",
            "code": 429,
            "metadata": {
              "provider_name": "OpenRouter"
            }
          }
        }
        """

        let message = OpenRouterAIService.decodeErrorMessage(from: Data(json.utf8))

        XCTAssertEqual(message, "OpenRouter error (429): Rate limit exceeded. Provider: OpenRouter.")
    }

    func testDecodeOpenRouterErrorMessageOmitsProviderSuffixWhenMissing() async throws {
        let json = """
        {
          "error": {
            "message": "Invalid API key",
            "code": 401,
            "metadata": {}
          }
        }
        """

        let message = OpenRouterAIService.decodeErrorMessage(from: Data(json.utf8))

        XCTAssertEqual(message, "OpenRouter error (401): Invalid API key.")
    }
}
