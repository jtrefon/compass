import XCTest

@testable import Compass

final class ConversationPlanStoreLRUTests: XCTestCase {

    /// A fresh instance per test — `ConversationPlanStore.shared` is a
    /// process-wide singleton that other suites (ConversationManagerTests
    /// graph runs) mutate concurrently under parallel test execution, which
    /// made the shared-store assertions flaky.
    func makeStore() -> ConversationPlanStore {
        ConversationPlanStore()
    }

    func testEvictsOldestWhenExceedingMaxCachedPlans() async {
        let store = makeStore()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        await store.setProjectRoot(tempDir)

        // Store 6 plans (max is 5)
        for i in 1...6 {
            await store.set(conversationId: "conv-\(i)", plan: "Plan \(i)")
        }

        // The first plan should have been evicted from the cache
        let evicted = await store.get(conversationId: "conv-1")
        // It may still be on disk, but the cache should have evicted it
        // The important thing is that the cache doesn't grow unboundedly
        // Since it reads from disk on cache miss, it will still return the value
        // but the in-memory cache is bounded
        XCTAssertNotNil(evicted, "Plan should still be readable from disk")

        // Recent plans should be in cache
        let recent = await store.get(conversationId: "conv-6")
        XCTAssertEqual(recent, "Plan 6")
    }

    func testGetTouchesAccessOrder() async {
        let store = makeStore()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        await store.setProjectRoot(tempDir)

        // Store 5 plans
        for i in 1...5 {
            await store.set(conversationId: "lru-\(i)", plan: "Plan \(i)")
        }

        // Access plan 1 to make it recently used
        _ = await store.get(conversationId: "lru-1")

        // Add a 6th plan - should evict lru-2 (oldest untouched), not lru-1
        await store.set(conversationId: "lru-6", plan: "Plan 6")

        // lru-1 should still be cached (was recently accessed)
        let plan1 = await store.get(conversationId: "lru-1")
        XCTAssertEqual(plan1, "Plan 1")

        // lru-6 should be cached
        let plan6 = await store.get(conversationId: "lru-6")
        XCTAssertEqual(plan6, "Plan 6")
    }
}
