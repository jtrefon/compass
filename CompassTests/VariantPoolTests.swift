import XCTest
@testable import Compass

/// VariantPoolStore: anchoring, retrieval, backtracking, eviction.
@MainActor
final class VariantPoolStoreTests: XCTestCase {
    private func makePool(paneID: FileEditorStateManager.PaneID = .primary,
                          anchor: String, cursor: Int) -> VariantPool {
        VariantPool(
            id: UUID(), paneID: paneID, anchorPrefix: anchor, anchorCursor: cursor,
            variants: [], lastHitAt: Date(), byteSize: 0
        )
    }

    func testActivePoolPicksLongestMatchingAnchor() async {
        let store = VariantPoolStore(byteBudget: 1_000_000)
        await store.upsert(makePool(anchor: "$p", cursor: 2))
        await store.upsert(makePool(anchor: "$plugin", cursor: 7))

        // Typing path passes through both anchors — the longest wins.
        let active = await store.activePool(paneID: .primary, bufferBeforeCursor: "$plugin->method")
        XCTAssertEqual(active?.anchorPrefix, "$plugin")
    }

    func testBackspaceReanchorsToOlderPool() async {
        let store = VariantPoolStore(byteBudget: 1_000_000)
        await store.upsert(makePool(anchor: "$p", cursor: 2))
        await store.upsert(makePool(anchor: "$plugin", cursor: 7))

        // Backspaced past the newer branch — the older pool serves.
        let active = await store.activePool(paneID: .primary, bufferBeforeCursor: "$plu")
        XCTAssertEqual(active?.anchorPrefix, "$p")
    }

    func testNoAnchorMatchReturnsNil() async {
        let store = VariantPoolStore(byteBudget: 1_000_000)
        await store.upsert(makePool(anchor: "$plugin", cursor: 7))

        let active = await store.activePool(paneID: .primary, bufferBeforeCursor: "function foo")
        XCTAssertNil(active)
    }

    /// The PHP scenario: a pool was anchored on line 3 ($plugin); the user
    /// moves to a NEW line and types "$". The newline between the branch
    /// point and the cursor must make the pool stale — otherwise its
    /// temp-0.7 variants get served as garbage suggestions.
    func testPoolIsStaleWhenCursorMovedToNewLine() async {
        let store = VariantPoolStore(byteBudget: 1_000_000)
        let branchBuffer = "$plugin->method();\n"
        let pool = VariantPool(
            id: UUID(), paneID: .primary,
            anchorPrefix: String(branchBuffer.suffix(10)),
            anchorCursor: branchBuffer.count,
            variants: [InlineCompletionVariant(
                id: UUID(), text: "$return", temperature: 0.7,
                bannedTokenCount: 3, createdAt: Date()
            )],
            lastHitAt: Date(), byteSize: 0
        )
        await store.upsert(pool)

        // Same line continuation → pool active.
        let sameLine = await store.activePool(paneID: .primary, bufferBeforeCursor: branchBuffer + "->")
        XCTAssertNotNil(sameLine, "continuing on the same line keeps the pool active")

        // New line → stale.
        let newLine = await store.activePool(paneID: .primary, bufferBeforeCursor: branchBuffer + "\n$")
        XCTAssertNil(newLine, "a newline after the branch point must invalidate the pool")
    }

    func testEvictionUnderByteBudgetEvictsLRU() async {
        let store = VariantPoolStore(byteBudget: 500)
        await store.upsert(makePool(anchor: "first", cursor: 5))
        // Bump lastHitAt of the first pool via a retrieval hit.
        _ = await store.activePool(paneID: .primary, bufferBeforeCursor: "firstline")
        // Second pool exceeds the budget alone → LRU (first) evicted.
        let big = VariantPool(
            id: UUID(), paneID: .primary, anchorPrefix: "big",
            anchorCursor: 0, variants: [], lastHitAt: Date(), byteSize: 600
        )
        await store.upsert(big)

        let remaining = await store.activePool(paneID: .primary, bufferBeforeCursor: "firstline")
        XCTAssertNil(remaining, "LRU pool should have been evicted")
    }

    func testResetClearsPane() async {
        let store = VariantPoolStore(byteBudget: 1_000_000)
        await store.upsert(makePool(anchor: "$p", cursor: 2))
        await store.reset(paneID: .primary)

        let active = await store.activePool(paneID: .primary, bufferBeforeCursor: "$plugin")
        XCTAssertNil(active)
    }
}

/// VariantPoolService: chaining, dedup, revision abort — with a mock provider.
@MainActor
final class VariantPoolServiceTests: XCTestCase {
    private func makeService(provider: MockVariantProvider) -> VariantPoolService {
        VariantPoolService(provider: provider)
    }

    func testChainFillsPoolUpToFiveVariants() async throws {
        let provider = MockVariantProvider()
        provider.texts = ["one", "two", "three", "four", "five", "six"]
        provider.firstTokens = [1, 2, 3, 4, 5, 6]
        let service = makeService(provider: provider)

        await service.registerDeviation(
            paneID: .primary,
            bufferBeforeCursor: "$plugin->m",
            cursor: 11,
            prefix: "$plugin->m",
            suffix: "ethod();",
            maxTokens: 8
        )

        let variants = try await waitForVariants(service, count: 5)
        XCTAssertEqual(variants.map(\.text), ["one", "two", "three", "four", "five"])
        XCTAssertEqual(provider.bansSeen.count, 5)
        // Each subsequent variant bans the accumulated first tokens.
        XCTAssertEqual(provider.bansSeen[0], [])
        XCTAssertEqual(provider.bansSeen[1], [1])
        XCTAssertEqual(provider.bansSeen[2], [1, 2])
        XCTAssertEqual(provider.bansSeen[3], [1, 2, 3])
        XCTAssertEqual(provider.bansSeen[4], [1, 2, 3, 4])
    }

    func testDedupSkipsSimilarVariant() async throws {
        let provider = MockVariantProvider()
        // "one" duplicates the first variant exactly — must be skipped.
        provider.texts = ["one", "one", "three", "four", "five"]
        provider.firstTokens = [1, 2, 3, 4, 5]
        let service = makeService(provider: provider)

        await service.registerDeviation(
            paneID: .primary,
            bufferBeforeCursor: "foo",
            cursor: 3,
            prefix: "foo",
            suffix: "",
            maxTokens: 8
        )

        let variants = try await waitForVariants(service, count: 4)
        XCTAssertEqual(variants.map(\.text), ["one", "three", "four", "five"])
        XCTAssertEqual(provider.firstTokensRequested, 4, "deduped variant must not consume a first token")
    }

    func testNewDeviationAbortsRunningChain() async throws {
        let provider = MockVariantProvider()
        provider.texts = ["one", "two", "three", "four", "five"]
        provider.firstTokens = [1, 2, 3, 4, 5]
        provider.delayPerStreamMs = 80
        let service = makeService(provider: provider)

        await service.registerDeviation(
            paneID: .primary, bufferBeforeCursor: "foo", cursor: 3,
            prefix: "foo", suffix: "", maxTokens: 8
        )
        try await Task.sleep(nanoseconds: 40_000_000)
        // New deviation before the chain completes → old chain must stop.
        await service.registerDeviation(
            paneID: .primary, bufferBeforeCursor: "foobar", cursor: 6,
            prefix: "foobar", suffix: "", maxTokens: 8
        )

        let variants = try await waitForVariants(service, count: 1)
        XCTAssertEqual(variants.count, 1, "aborted chain must not keep filling the old pool")
        XCTAssertLessThan(provider.callsMade, 5)
    }

    private func waitForVariants(_ service: VariantPoolService, count: Int) async throws -> [InlineCompletionVariant] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let variants = await service.variants(paneID: .primary)
            if variants.count >= count {
                return variants
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let variants = await service.variants(paneID: .primary)
        XCTFail("timeout waiting for \(count) variants, got \(variants.count)")
        return variants
    }
}
