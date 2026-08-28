import Testing

@testable import Compass

struct ToolTimeoutCircuitBreakerTests {
    @Test("Trips after threshold of identical consecutive timeouts")
    func tripsAfterThreshold() async {
        let breaker = ToolTimeoutCircuitBreaker()
        let key = "run_command:npm run dev"

        #expect(await breaker.record(normalizedKey: key).tripped == false)
        #expect(await breaker.record(normalizedKey: key).tripped == false)
        let third = await breaker.record(normalizedKey: key)
        #expect(third.tripped == true)
        #expect(third.count == 3)
    }

    @Test("Different commands keep independent streaks")
    func independentKeys() async {
        let breaker = ToolTimeoutCircuitBreaker()
        #expect(await breaker.record(normalizedKey: "run_command:a").tripped == false)
        #expect(await breaker.record(normalizedKey: "run_command:b").tripped == false)
        #expect(await breaker.record(normalizedKey: "run_command:a").tripped == false)
    }

    @Test("A successful execution resets the streak")
    func resetClearsStreak() async {
        let breaker = ToolTimeoutCircuitBreaker()
        _ = await breaker.record(normalizedKey: "run_command:build")
        _ = await breaker.record(normalizedKey: "run_command:build")
        await breaker.reset(normalizedKey: "run_command:build")
        #expect(await breaker.record(normalizedKey: "run_command:build").tripped == false)
    }
}

// MARK: - ToolTimeoutCenter (deadline/expiry semantics)

@MainActor
struct ToolTimeoutCenterTests {
    @Test("Entry survives countdown ticks after deadline passes — watchdog can still expire it")
    func expirySurvivesTicks() async throws {
        let center = ToolTimeoutCenter()
        center.begin(toolCallId: "call_t", toolName: "bash", targetFile: nil, timeoutSeconds: 0.05)
        try await Task.sleep(for: .milliseconds(1200))  // past the 1s countdown tick
        #expect(center.isExpired(toolCallId: "call_t") == true, "deadline passed but entry must remain")
        #expect(center.remainingSeconds(toolCallId: "call_t") == 0)
        #expect(center.isCancelled(toolCallId: "call_t") == false)
    }

    @Test("Explicit cancellation is distinct from expiry")
    func explicitCancelIsDistinct() async {
        let center = ToolTimeoutCenter()
        center.begin(toolCallId: "call_c", toolName: "bash", targetFile: nil, timeoutSeconds: 600)
        center.cancel(toolCallId: "call_c")
        #expect(center.isCancelled(toolCallId: "call_c") == true)
        #expect(center.isExpired(toolCallId: "call_c") == false, "cancelled tools must not surface as timeouts")
    }

    @Test("Finish removes the entry")
    func finishClearsState() async {
        let center = ToolTimeoutCenter()
        center.begin(toolCallId: "call_f", toolName: "bash", targetFile: nil, timeoutSeconds: 600)
        center.finish(toolCallId: "call_f")
        #expect(center.isExpired(toolCallId: "call_f") == false)
        #expect(center.remainingSeconds(toolCallId: "call_f") == nil)
    }
}
