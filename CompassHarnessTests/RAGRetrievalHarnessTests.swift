import XCTest
@testable import Compass

/// Offline RAG verification: seeds a real vector store, wires it the way
/// DependencyContainer does, and asserts ContextTool returns genuine hits.
/// Would have caught the coordinator-retention and dimension-mismatch bugs.
@MainActor
final class RAGRetrievalHarnessTests: XCTestCase {

    private func makeSeededStore() async throws -> (store: VectorStoreService, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness_rag_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let config = VectorStoreConfiguration(
            storePath: root.appendingPathComponent("vector_store"),
            dimensions: 4,
            factoryString: "IDMap,Flat"
        )
        let store = VectorStoreService.create(with: config)
        try await store.load()
        try await store.addEntry(text: "the navigation bar uses a custom NSToolbarItem", vector: [1, 0, 0, 0], source: "harness")
        try await store.addEntry(text: "session restore persists open editor tabs", vector: [0, 1, 0, 0], source: "harness")
        try await store.save()
        return (store, root)
    }

    func testContextToolReturnsSeededEntries() async throws {
        let (store, root) = try await makeSeededStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = ContextTool(vectorStoreService: store, embedder: TestEmbedder())
        let result = try await tool.execute(arguments: ToolArguments([
            "query": "navigation bar",
            "max_results": 5,
        ]))

        XCTAssertTrue(result.contains("status: success"), "Expected success status. Got: \(result)")
        XCTAssertTrue(result.contains("NSToolbarItem"), "Seeded text must be retrieved. Got: \(result)")
        XCTAssertFalse(result.contains("status: error"), "Retrieval must not be masked as an error")
    }

    func testContextToolReportsErrorsInsteadOfEmptySuccess() async throws {
        let (store, root) = try await makeSeededStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // An embedder whose vectors have the WRONG dimension — the FAISS index
        // throws; ContextTool must surface it, not claim "no context".
        let broken = ContextTool(vectorStoreService: store, embedder: WrongDimensionEmbedder())
        let result = try await broken.execute(arguments: ToolArguments([
            "query": "anything",
            "max_results": 5,
        ]))

        XCTAssertTrue(result.contains("status: error"), "Dimension mismatch must surface as an error. Got: \(result)")
    }
}

/// 4-dim deterministic embeddings (matches the seeded store).
private struct TestEmbedder: MemoryEmbeddingGenerating {
    var modelIdentifier: String { "test-4d" }
    func generateEmbedding(for text: String) async throws -> [Float] {
        let words = text.split(separator: " ").map(String.init)
        return [
            Float(words.count % 2),
            Float(words.count > 3 ? 1 : 0),
            Float(text.contains("navigation") ? 1 : 0),
            Float(text.contains("toolbar") ? 1 : 0),
        ]
    }
}

/// 3-dim embeddings — any add/search against the 4-dim index must fail loudly.
private struct WrongDimensionEmbedder: MemoryEmbeddingGenerating {
    var modelIdentifier: String { "test-3d" }
    func generateEmbedding(for text: String) async throws -> [Float] {
        [1, 0, 0]
    }
}
