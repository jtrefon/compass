import XCTest
@testable import Compass

/// Direct test of GoogleWebSearchTool execution.
/// Runs against real Google search to validate the full WKWebView pipeline.
@MainActor
final class WebSearchHarnessTests: XCTestCase {

    func testWebSearchReturnsResults() async throws {
        let tool = GoogleWebSearchTool()
        let result = try await tool.execute(arguments: ToolArguments([
            "query": "React unit testing libraries comparison",
            "max_results": 5
        ]))

        print("[HARNESS][INFO] web_search result (\(result.count) chars):\n\(result)")

        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("search results") ||
            result.localizedCaseInsensitiveContains("no search results"),
            "Result should contain search results header or explicit no-results message"
        )

        if result.localizedCaseInsensitiveContains("BLOCKED") {
            print("[HARNESS][WARN] Google CAPTCHA triggered — skipping result validation")
            return
        }

        if result.localizedCaseInsensitiveContains("no search results found") {
            XCTFail("Web search returned no results — extraction may be broken. Result: \(result)")
            return
        }

        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("[1]") || result.contains("URL:"),
            "Result should contain at least one numbered result or URL"
        )
    }

    func testWebSearchFailsGracefullyOnEmptyQuery() async throws {
        let tool = GoogleWebSearchTool()
        let result = try await tool.execute(arguments: ToolArguments([
            "query": ""
        ]))

        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("error") || result.localizedCaseInsensitiveContains("required"),
            "Should return error for empty query. Got: \(result)"
        )
    }

    func testWebSearchFailsGracefullyOnMissingQuery() async throws {
        let tool = GoogleWebSearchTool()
        let result = try await tool.execute(arguments: ToolArguments([
            "max_results": 5
        ]))

        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("error") || result.localizedCaseInsensitiveContains("required"),
            "Should return error for missing query. Got: \(result)"
        )
    }
}
