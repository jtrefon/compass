import Foundation
import XCTest
@testable import Compass

final class VectorStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorstore_test_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func makeService() -> VectorStoreService {
        let config = VectorStoreConfiguration(
            storePath: tempDir,
            dimensions: 4,
            factoryString: "IDMap,Flat"
        )
        return VectorStoreService.create(with: config)
    }

    func testAddAndSearch() async throws {
        let service = makeService()
        try await service.load()

        try await service.addEntry(
            text: "test entry",
            vector: [1.0, 0.0, 0.0, 0.0],
            source: "test"
        )

        let results = try await service.search(queryVector: [1.0, 0.0, 0.0, 0.0], limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThan(results[0].score, 0.9)
    }

    func testPersistence() async throws {
        let config = VectorStoreConfiguration(
            storePath: tempDir,
            dimensions: 4,
            factoryString: "IDMap,Flat"
        )

        do {
            let service = VectorStoreService.create(with: config)
            try await service.load()
            try await service.addEntry(
                text: "persist me",
                vector: [0.0, 1.0, 0.0, 0.0],
                source: "test"
            )
            try await service.save()
        }

        do {
            let service = VectorStoreService.create(with: config)
            try await service.load()
            let results = try await service.search(queryVector: [0.0, 1.0, 0.0, 0.0], limit: 5)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].metadata?.text, "persist me")
        }
    }

    func testBatchAdd() async throws {
        let service = makeService()
        try await service.load()

        let catA: String? = nil
        let catB: String? = nil
        let catC: String? = nil
        let ids = try await service.addBatch(entries: [
            (text: "a", vector: [1, 0, 0, 0], source: "test", category: catA),
            (text: "b", vector: [0, 1, 0, 0], source: "test", category: catB),
            (text: "c", vector: [0, 0, 1, 0], source: "test", category: catC),
        ])
        XCTAssertEqual(ids.count, 3)

        let results = try await service.search(queryVector: [1, 0, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].metadata?.text, "a")
    }

    func testRemove() async throws {
        let service = makeService()
        try await service.load()

        let id = try await service.addEntry(
            text: "delete me",
            vector: [1, 0, 0, 0],
            source: "test"
        )
        let count1 = await service.indexCount
        XCTAssertEqual(count1, 1)

        try await service.removeEntry(id: id)
        let count2 = await service.indexCount
        XCTAssertEqual(count2, 0)
    }

    func testRemoveAll() async throws {
        let service = makeService()
        try await service.load()

        let catX: String? = nil
        let catY: String? = nil
        try await service.addBatch(entries: [
            (text: "x", vector: [1, 0, 0, 0], source: "test", category: catX),
            (text: "y", vector: [0, 1, 0, 0], source: "test", category: catY),
        ])
        try await service.removeAll()
        let indexCount3 = await service.indexCount
        let entryCount = await service.entryCount
        XCTAssertEqual(indexCount3, 0)
        XCTAssertEqual(entryCount, 0)
    }

    func testCosineSimilarity() async throws {
        let service = makeService()
        try await service.load()

        try await service.addEntry(
            text: "similar",
            vector: [0.8, 0.6, 0.0, 0.0],
            source: "test"
        )
        try await service.addEntry(
            text: "different",
            vector: [0.0, 0.0, 0.8, 0.6],
            source: "test"
        )

        let results = try await service.search(queryVector: [1.0, 0.0, 0.0, 0.0], limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].metadata?.text, "similar")
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }
    // MARK: - Remove + reload id-mapping regression

    func testIdMappingSurvivesRemovalAndReload() async throws {
        let config = VectorStoreConfiguration(
            storePath: tempDir,
            dimensions: 4,
            factoryString: "IDMap,Flat"
        )

        do {
            let service = VectorStoreService.create(with: config)
            try await service.load()
            let a = try await service.addEntry(text: "alpha", vector: [1, 0, 0, 0], source: "test")
            let b = try await service.addEntry(text: "beta", vector: [0, 1, 0, 0], source: "test")
            let c = try await service.addEntry(text: "gamma", vector: [0, 0, 1, 0], source: "test")
            try await service.removeEntry(id: b)
            try await service.save()

            // Reload into a fresh service instance (as after an app restart).
            let reloaded = VectorStoreService.create(with: config)
            try await reloaded.load()

            let alpha = try await reloaded.search(queryVector: [1, 0, 0, 0], limit: 5)
            XCTAssertEqual(alpha.first?.metadata?.text, "alpha", "Removal must not corrupt id mapping after reload")
            let gamma = try await reloaded.search(queryVector: [0, 0, 1, 0], limit: 5)
            XCTAssertEqual(gamma.first?.metadata?.text, "gamma")
            XCTAssertEqual(a, alpha.first?.metadata?.id)
            XCTAssertEqual(c, gamma.first?.metadata?.id)
        }
    }

}

final class FAISSVectorIndexTests: XCTestCase {

    func testFAISSIndexLifecycle() throws {
        let idx = FAISSVectorIndex(dimensions: 4)
        try idx.add(id: 1, vector: [1, 0, 0, 0])
        try idx.add(id: 2, vector: [0, 1, 0, 0])
        XCTAssertEqual(idx.count, 2)

        let results = try idx.search(query: [1, 0, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, 1)
    }

    func testFAISSRemove() throws {
        let idx = FAISSVectorIndex(dimensions: 4)
        try idx.add(id: 1, vector: [1, 0, 0, 0])
        try idx.add(id: 2, vector: [0, 1, 0, 0])

        try idx.remove(ids: [1])
        XCTAssertEqual(idx.count, 1)

        let results = try idx.search(query: [1, 0, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 2)
    }

    func testFAISSReset() throws {
        let idx = FAISSVectorIndex(dimensions: 4)
        try idx.add(id: 1, vector: [1, 0, 0, 0])
        try idx.reset()
        XCTAssertEqual(idx.count, 0)
    }

    func testFAISSBatch() throws {
        let idx = FAISSVectorIndex(dimensions: 4)
        try idx.addBatch(ids: [1, 2, 3], vectors: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
        ])
        XCTAssertEqual(idx.count, 3)
    }

}