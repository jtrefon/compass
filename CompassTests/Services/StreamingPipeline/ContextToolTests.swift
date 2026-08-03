import XCTest
@testable import Compass

final class ContextToolTests: XCTestCase {

    func testMissingQueryReturnsError() async throws {
        let tool = ContextTool(vectorStoreService: nil)
        let args = ToolArguments([:])
        let result = try await tool.execute(arguments: args)
        XCTAssertTrue(result.contains("Missing query"))
    }

    func testNilVectorStoreReturnsUnavailable() async throws {
        let tool = ContextTool(vectorStoreService: nil)
        let args = ToolArguments(["query": "test"])
        let result = try await tool.execute(arguments: args)
        XCTAssertTrue(result.contains("Knowledge store not available"))
    }

    func testMaxResultsClampedToRange() async throws {
        let tool = ContextTool(vectorStoreService: nil)
        let args = ToolArguments(["query": "test", "max_results": 100])
        let result = try await tool.execute(arguments: args)
        // nil store → unavailable, but clamp should not crash
        XCTAssertTrue(result.contains("Knowledge store not available"))
    }

    func testMaxResultsClampedMinimum() async throws {
        let tool = ContextTool(vectorStoreService: nil)
        let args = ToolArguments(["query": "test", "max_results": 0])
        let result = try await tool.execute(arguments: args)
        XCTAssertTrue(result.contains("Knowledge store not available"))
    }

    func testToolNameAndDescriptionPresent() {
        let tool = ContextTool(vectorStoreService: nil)
        XCTAssertEqual(tool.name, "context")
        XCTAssertTrue(tool.description.contains("Retrieve prior conversation"))
    }

    func testParametersDefined() {
        let tool = ContextTool(vectorStoreService: nil)
        let params = tool.parameters
        XCTAssertNotNil(params["properties"])
        guard let properties = params["properties"] as? [String: Any] else { XCTFail(); return }
        XCTAssertNotNil(properties["query"])
        XCTAssertNotNil(properties["max_results"])
        guard let required = params["required"] as? [String] else { XCTFail(); return }
        XCTAssertTrue(required.contains("query"))
    }
}
