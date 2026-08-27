import XCTest
@testable import Compass

final class TransportFailureClassifierTests: XCTestCase {

    // MARK: - Tier 1: cancellation

    func testCancellationErrorClassifiesFirst() {
        XCTAssertEqual(
            TransportFailureClassifier.classify(CancellationError()),
            .cancellation
        )
    }

    // MARK: - Tier 2: typed provider status codes

    func testTypedRateLimit429() {
        let error = OpenRouterServiceError.serverError(429, body: "too many requests")
        XCTAssertEqual(TransportFailureClassifier.classify(error), .rateLimit(status: 429))
    }

    func testTypedPaymentRequired402() {
        let error = OpenRouterServiceError.serverError(402, body: "insufficient credits")
        XCTAssertEqual(TransportFailureClassifier.classify(error), .paymentRequired(status: 402))
    }

    func testTypedServerError5xx() {
        let error = OpenRouterServiceError.serverError(503, body: nil)
        XCTAssertEqual(TransportFailureClassifier.classify(error), .server(status: 503))
    }

    func testStreamTimeoutIsNetwork() {
        let error = OpenRouterServiceError.streamTimeout(.idle)
        if case .network = TransportFailureClassifier.classify(error) {
            // expected
        } else {
            XCTFail("stream timeout must classify as network")
        }
    }

    // MARK: - Tier 3: URLError codes

    func testTransientURLErrorsClassifyAsNetwork() {
        let transientCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        ]
        for code in transientCodes {
            if case .network = TransportFailureClassifier.classify(URLError(code)) {
                continue
            }
            XCTFail("URLError code \(code.rawValue) must classify as network")
        }
    }

    func testNonTransientURLErrorIsServer() {
        if case .server = TransportFailureClassifier.classify(URLError(.badURL)) {
            // expected
        } else {
            XCTFail("badURL must not be transient network")
        }
    }

    func testNSErrorDomainIsHonored() {
        let nsError = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        if case .network = TransportFailureClassifier.classify(nsError) {
            // expected
        } else {
            XCTFail("NSURLErrorDomain timed-out must classify as network")
        }
    }

    // MARK: - Tier 4/5: phrase fallback

    func testPhraseFallbackStillWorksForUntypedWrappers() {
        // Errors that lost their type upstream (wrapped into message strings).
        let wrapped = AppError.aiServiceError("HTTP 429 too many requests")
        if case .rateLimit = TransportFailureClassifier.classify(wrapped) {
            // expected via fallback
        } else {
            XCTFail("legacy wrapped 429 must still reach rate-limit policy")
        }

        let balance = AppError.aiServiceError("Provider has insufficient balance / more credits needed")
        if case .paymentRequired = TransportFailureClassifier.classify(balance) {
            // expected
        } else {
            XCTFail("legacy insufficient-balance phrasing must still be caught")
        }

        let offline = AppError.aiServiceError("The request timed out.")
        if case .network = TransportFailureClassifier.classify(offline) {
            // expected
        } else {
            XCTFail("legacy timeout phrasing must still reach network schedule")
        }
    }

    func testUnclassifiedShapeDoesNotPanic() {
        if case .unclassified = TransportFailureClassifier.classify(
            AppError.aiServiceError("something entirely novel happened")
        ) {
            // expected
        } else {
            XCTFail("novel shapes must fall through as unclassified, not guess")
        }
    }

    // MARK: - Coordinator predicate parity (policy order preserved)

    private final class NoopAIService: AIService, @unchecked Sendable {
        var preservesCache: Bool { false }
        func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
            AIServiceResponse(content: "", toolCalls: nil)
        }
        func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
            AIServiceResponse(content: "", toolCalls: nil)
        }
        func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
            AIServiceResponse(content: "", toolCalls: nil)
        }
    }

    @MainActor
    func testCoordinatorPredicatesMatchClassifier() {
        let coordinator = AIInteractionCoordinator(aiService: NoopAIService(), eventBus: EventBus())

        XCTAssertTrue(coordinator.isRateLimitError(
            OpenRouterServiceError.serverError(429, body: nil)))
        XCTAssertFalse(coordinator.isRateLimitError(
            OpenRouterServiceError.serverError(500, body: nil)))

        XCTAssertTrue(coordinator.isInsufficientBalanceError(
            OpenRouterServiceError.serverError(402, body: nil)))
        XCTAssertFalse(coordinator.isInsufficientBalanceError(
            OpenRouterServiceError.serverError(500, body: nil)))

        XCTAssertTrue(coordinator.isNetworkConnectivityError(
            URLError(.notConnectedToInternet)))
        XCTAssertTrue(coordinator.isNetworkConnectivityError(
            AppError.networkError("offline")))
        XCTAssertFalse(coordinator.isNetworkConnectivityError(
            OpenRouterServiceError.serverError(402, body: nil)))
    }
}
