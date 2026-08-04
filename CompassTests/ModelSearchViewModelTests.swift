import XCTest
@testable import Compass

@MainActor
final class ModelSearchViewModelTests: XCTestCase {

    /// Custom endpoints expose bare model ids (gpt-4o, llama3) that never match
    /// the OpenRouter-qualified popular list — the opened picker must still
    /// show the provider's models without typing.
    func testEmptyQueryShowsCustomEndpointModels() {
        let vm = ModelSearchViewModel()
        vm.allModels = [
            OpenRouterModel(id: "gpt-4o", name: "GPT-4o"),
            OpenRouterModel(id: "llama3", name: "Llama 3"),
            OpenRouterModel(id: "qwen2.5-coder", name: "Qwen 2.5 Coder"),
        ]

        let displayed = vm.displayModels

        XCTAssertTrue(displayed.contains { $0.id == "gpt-4o" }, "Custom endpoint model must be visible with an empty query")
        XCTAssertTrue(displayed.contains { $0.id == "llama3" })
        XCTAssertTrue(displayed.contains { $0.id == "qwen2.5-coder" })
    }

    /// Recents stay pinned first, then the catalog.
    func testRecentsRankedFirstThenCatalog() {
        let vm = ModelSearchViewModel()
        vm.allModels = [
            OpenRouterModel(id: "openai/gpt-4o", name: "GPT-4o"),
            OpenRouterModel(id: "anthropic/claude-3.5-sonnet", name: "Claude"),
        ]
        vm.recordSelection("openai/gpt-4o")

        let displayed = vm.displayModels
        XCTAssertEqual(displayed.first?.id, "openai/gpt-4o", "Recent selection must rank first")
        XCTAssertEqual(displayed.count, 2, "Catalog fallback fills the rest")
    }
}
