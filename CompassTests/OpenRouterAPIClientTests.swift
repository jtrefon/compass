import XCTest
@testable import Compass

final class OpenRouterAPIClientTests: XCTestCase {
    func testSSEPayloadsJoinMultilineDataEvents() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"<think>\"}}",
            "data: ,\"usage\":{\"prompt_tokens\":1}}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}",
            "",
            "data: [DONE]"
        ]

        let payloads = OpenRouterAPIClient.ssePayloads(from: lines)

        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(
            payloads[0],
            "{\"choices\":[{\"delta\":{\"content\":\"<think>\"}}\n,\"usage\":{\"prompt_tokens\":1}}"
        )
        XCTAssertEqual(payloads[1], "{\"choices\":[{\"delta\":{\"content\":\"done\"}}]}")
        XCTAssertEqual(payloads[2], "[DONE]")
    }

    func testOpenRouterServiceRecoversMinimaxToolCallMarkup() {
        let content = """
        Completed useTodos hook created Next: reviewing retrieved context and finalizing when the objective is satisfied in src/components.
        <minimax:tool_call>
        <invoke name="list_files">
        <parameter name="path">/tmp/project/src/components</parameter>
        </invoke>
        </minimax:tool_call>
        """

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?.name, "ls")
        XCTAssertEqual(toolCalls?.first?.arguments["path"] as? String, "/tmp/project/src/components")
    }

    func testOpenRouterServiceRecoversStructuredXMLToolCallMarkup() {
        let content = """
        I'll create the package.json and test file now.
        <tool_call>
        <tool name="write_file">
        <arg name="path">/tmp/project/package.json</arg>
        <arg name="content">{"scripts":{"test":"vitest run"}}</arg>
        </tool>
        <tool name="create_file">
        <arg name="path">/tmp/project/src/utils.test.js</arg>
        <arg name="content">import { describe } from 'vitest'</arg>
        </tool>
        </tool_call>
        """

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 2)
        XCTAssertEqual(toolCalls?.first?.name, "write")
        XCTAssertEqual(toolCalls?.first?.arguments["path"] as? String, "/tmp/project/package.json")
        XCTAssertEqual(toolCalls?.last?.name, "write")
        XCTAssertEqual(toolCalls?.last?.arguments["path"] as? String, "/tmp/project/src/utils.test.js")
    }

    func testOpenRouterServiceRecoversStructuredXMLToolCallMarkupWithParameterTags() {
        let content = """
        <tool_call>
        <tool name="list_files">
        <parameter name="path">/tmp/project/src</parameter>
        </tool>
        </tool_call>
        """

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?.name, "ls")
        XCTAssertEqual(toolCalls?.first?.arguments["path"] as? String, "/tmp/project/src")
    }

    func testOpenRouterServiceRecoversLegacyToolCodeMarkup() {
        let content = """
        <tool_code>
        list_files
        <param name="path">src/services</param>
        </tool_code>
        """

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?.name, "ls")
        XCTAssertEqual(toolCalls?.first?.arguments["path"] as? String, "src/services")
    }

    func testOpenRouterServiceRecoversLegacySelfClosingToolMarkup() {
        let content = #"""
        <tool_code>
        <tool name="write_file"
        path="package.json"
        content="{&quot;name&quot;:&quot;utils-project&quot;}"
        />
        </tool_code>
        """#

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?.name, "write")
        XCTAssertEqual(toolCalls?.first?.arguments["path"] as? String, "package.json")
        XCTAssertEqual(toolCalls?.first?.arguments["content"] as? String, #"{"name":"utils-project"}"#)
    }

    func testOpenRouterServiceNormalizesRecoveredMinimaxToolAliases() {
        let content = """
        <minimax:tool_call>
        <invoke name="list_directory">
        <parameter name="path">/tmp/project</parameter>
        </invoke>
        <invoke name="cli-mcp-server_run_command">
        <parameter name="command">ls -la</parameter>
        </invoke>
        </minimax:tool_call>
        """

        let toolCalls = OpenRouterAIService.extractFallbackToolCalls(from: content)

        XCTAssertEqual(toolCalls?.count, 2)
        XCTAssertEqual(toolCalls?.first?.name, "ls")
        XCTAssertEqual(toolCalls?.last?.name, "bash")
        XCTAssertEqual(toolCalls?.last?.arguments["command"] as? String, "ls -la")
    }

    // MARK: - Transport circuit breaker (Tier 2: provider/model fallback)

    func testCircuitBreakerTripsOnTransportFailureAndRoutesToFallback() {
        setenv("COMPASS_FALLBACK_MODEL_ID", "openai/gpt-4o-mini", 1)
        let breaker = TransportCircuitBreaker()
        let primary = "anthropic/claude-3.5-sonnet"

        // Healthy: primary model is used, breaker not tripped.
        XCTAssertFalse(breaker.isTripped)
        XCTAssertEqual(breaker.effectiveModel(for: primary), primary)

        // A transport/stall failure trips the breaker after the (default) threshold.
        breaker.recordTransportOrServerFailure(OpenRouterServiceError.streamTimeout(.idle))
        XCTAssertTrue(breaker.isTripped)
        XCTAssertEqual(breaker.effectiveModel(for: primary), "openai/gpt-4o-mini")

        // A successful request resets the breaker.
        breaker.recordTransportSuccess()
        XCTAssertFalse(breaker.isTripped)
        XCTAssertEqual(breaker.effectiveModel(for: primary), primary)
    }

    func testCircuitBreakerDoesNotTripOnClientErrors() {
        setenv("COMPASS_FALLBACK_MODEL_ID", "openai/gpt-4o-mini", 1)
        let breaker = TransportCircuitBreaker()
        let primary = "anthropic/claude-3.5-sonnet"

        // 4xx (bad request) and 429 (rate limit) are client-side; a different model
        // would not resolve them, so the breaker must ignore them.
        breaker.recordTransportOrServerFailure(OpenRouterServiceError.serverError(400, body: "bad request"))
        XCTAssertFalse(breaker.isTripped)
        XCTAssertEqual(breaker.effectiveModel(for: primary), primary)

        breaker.recordTransportOrServerFailure(OpenRouterServiceError.serverError(429, body: "rate limited"))
        XCTAssertFalse(breaker.isTripped)
        XCTAssertEqual(breaker.effectiveModel(for: primary), primary)
    }

    /// Reproduces the production silent-stall failure mode: a connection that has
    /// delivered response headers but then stops emitting body bytes (a wedged TCP
    /// socket / provider hang with no error). The liveness watcher must terminate the
    /// stream near the absolute deadline rather than hanging until the outer harness
    /// watchdog kills the process. This is the exact gap that let run 5 idle for 300s.
    func testStreamDeadlineFiresOnSilentBodyStall() async {
        let deadline = SSEStreamDeadline(
            idle: .seconds(1),
            absolute: .seconds(2),
            granularity: .milliseconds(100)
        )
        // A source that yields nothing and never completes.
        let stalled = AsyncStream<String> { _ in }

        let start = ContinuousClock.now
        var threw = false
        do {
            for try await _ in deadline.lines(from: stalled) {
                XCTFail("expected the liveness watcher to terminate the stream")
            }
        } catch {
            threw = true
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertTrue(threw, "silent body stall must surface a liveness error")
        XCTAssertLessThan(elapsed, .seconds(10), "watcher must fire near the absolute deadline, not hang")
    }
}
