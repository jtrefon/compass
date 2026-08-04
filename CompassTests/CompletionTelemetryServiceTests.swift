import XCTest
@testable import Compass

final class CompletionTelemetryServiceTests: XCTestCase {
    func testTelemetryRequestsReducedWorkloadAfterSlowSuggestions() async {
        let telemetry = CompletionTelemetryService()

        // Record 6 completions where 4 are slow (>=500ms) — triggers workload reduction
        for latencyMs in [450.0, 510.0, 300.0, 550.0, 600.0, 520.0] {
            await telemetry.recordShown(
                InlineSuggestionPresentation(
                    requestId: UUID(),
                    suggestionText: "test",
                    source: .local,
                    confidenceScore: 0.8,
                    latencyMs: latencyMs
                )
            )
        }

        let shouldReduceWorkload = await telemetry.shouldReduceWorkload()

        XCTAssertTrue(shouldReduceWorkload)
    }
}
