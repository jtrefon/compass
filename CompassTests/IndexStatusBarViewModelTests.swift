import XCTest
@testable import Compass

@MainActor
final class IndexStatusBarViewModelTests: XCTestCase {
    func testRemoteAIUsageDisplaysBalanceWhenProvided() {
        let eventBus = EventBus()
        let viewModel = IndexStatusBarViewModel(
            codebaseIndexProvider: { FakeCodebaseIndex() },
            eventBus: eventBus,
            refreshRemoteAIAccountBalance: { _ in },
            statsPollInterval: 60
        )

        eventBus.publish(OpenRouterUsageUpdatedEvent(
            providerName: "Kilo Code",
            modelId: "kilo-auto/balanced",
            runId: "run-1",
            usage: .init(
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30,
                costMicrodollars: 120_000,
                accountBalanceMicrodollars: 13_450_000
            ),
            contextLength: 100
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(viewModel.openRouterContextUsageText, "CTX 30/100")
        XCTAssertEqual(viewModel.remoteAICostText, "")
        XCTAssertEqual(viewModel.remoteAISpendText, "Kilo Code spent $0.12")
        XCTAssertEqual(viewModel.remoteAIBalanceText, "Kilo Code balance $13.45")
    }

    func testConversationCompletionTriggersDelayedBalanceRefresh() {
        let eventBus = EventBus()
        let refreshExpectation = expectation(description: "refresh balance")
        let viewModel = IndexStatusBarViewModel(
            codebaseIndexProvider: { FakeCodebaseIndex() },
            eventBus: eventBus,
            refreshRemoteAIAccountBalance: { runId in
                if runId == "run-42" {
                    refreshExpectation.fulfill()
                }
            },
            statsPollInterval: 60
        )

        _ = viewModel
        eventBus.publish(ConversationRunCompletedEvent(runId: "run-42"))

        wait(for: [refreshExpectation], timeout: 3.0)
    }
    func testContextDisplayResetsPerRun() {
        let eventBus = EventBus()
        let viewModel = IndexStatusBarViewModel(
            codebaseIndexProvider: { FakeCodebaseIndex() },
            eventBus: eventBus,
            refreshRemoteAIAccountBalance: { _ in },
            statsPollInterval: 60
        )

        // Run 1: estimate + authoritative usage.
        eventBus.publish(StreamingContextUsageEvent(runId: "run-1", estimatedPromptTokens: 10_000, isFinal: false))
        eventBus.publish(OpenRouterUsageUpdatedEvent(
            providerName: "OpenRouter", modelId: "m", runId: "run-1",
            usage: .init(promptTokens: 8_000, completionTokens: 2_000, totalTokens: 10_000,
                         costMicrodollars: 0, accountBalanceMicrodollars: 0),
            contextLength: 262_000
        ))

        // Run 2: new run, tiny usage — display must NOT include run 1's totals.
        eventBus.publish(StreamingContextUsageEvent(runId: "run-2", estimatedPromptTokens: 500, isFinal: false))
        eventBus.publish(OpenRouterUsageUpdatedEvent(
            providerName: "OpenRouter", modelId: "m", runId: "run-2",
            usage: .init(promptTokens: 400, completionTokens: 100, totalTokens: 500,
                         costMicrodollars: 0, accountBalanceMicrodollars: 0),
            contextLength: 262_000
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(viewModel.openRouterContextUsageText, "CTX 500/262K",
                       "Second run must not accumulate the first run's tokens")
    }

    func testSymbolBreakdownReflectsIndexStats() {
        let eventBus = EventBus()
        let viewModel = IndexStatusBarViewModel(
            codebaseIndexProvider: { StatsFakeCodebaseIndex() },
            eventBus: eventBus,
            refreshRemoteAIAccountBalance: { _ in },
            statsPollInterval: 60
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let breakdown = viewModel.symbolBreakdown
        XCTAssertEqual(breakdown?.classCount, 12)
        XCTAssertEqual(breakdown?.functionCount, 34)
        XCTAssertEqual(breakdown?.structCount, 5)
        XCTAssertEqual(breakdown?.enumCount, 6)
        XCTAssertEqual(breakdown?.protocolCount, 7)
        XCTAssertEqual(breakdown?.variableCount, 56)
        XCTAssertEqual(breakdown?.symbolCount, 90)
        XCTAssertEqual(viewModel.indexFilesText, "10/100")
        XCTAssertTrue(["OK", "WIP", "–"].contains(viewModel.acShortText),
                      "AC label must be one of the compact states")
    }
}

@MainActor
private final class StatsFakeCodebaseIndex: CodebaseIndexProtocol {
    var database: DatabaseManager

    init() {
        database = try! DatabaseManager(path: "/tmp/test_statusbar_stats_\(UUID().uuidString).db")
    }

    func start() {}
    func stop() {}
    func setEnabled(_ enabled: Bool) {}
    func reindexProject() {}

    func listIndexedFiles(matching query: String?, limit: Int, offset: Int) async throws -> [String] { [] }
    func findIndexedFiles(query: String, limit: Int) async throws -> [IndexedFileMatch] { [] }
    func readIndexedFile(path: String, startLine: Int?, endLine: Int?) throws -> String { "" }
    func searchIndexedText(pattern: String, limit: Int) async throws -> [String] { [] }
    func searchSymbols(nameLike query: String, limit: Int) async throws -> [Symbol] { [] }
    func searchSymbolsWithPaths(nameLike query: String, limit: Int) async throws -> [SymbolSearchResult] { [] }
    func getSummaries(projectRoot: URL, limit: Int) async throws -> [(path: String, summary: String)] { [] }

    func getStats() async throws -> IndexStats {
        IndexStats(
            indexedResourceCount: 10,
            aiEnrichedResourceCount: 10,
            aiEnrichableProjectFileCount: 100,
            totalProjectFileCount: 100,
            symbolCount: 90,
            classCount: 12,
            structCount: 5,
            enumCount: 6,
            protocolCount: 7,
            functionCount: 34,
            variableCount: 56,
            databaseSizeBytes: 1_048_576,
            databasePath: "",
            isDatabaseInWorkspace: false,
            averageQualityScore: 88,
            averageAIQualityScore: 0
        )
    }
}

@MainActor
private final class FakeCodebaseIndex: CodebaseIndexProtocol {
    var database: DatabaseManager

    init() {
        database = try! DatabaseManager(path: "/tmp/test_statusbar_\(UUID().uuidString).db")
    }

    func start() {}
    func stop() {}
    func setEnabled(_ enabled: Bool) {}
    func reindexProject() {}

    func listIndexedFiles(matching query: String?, limit: Int, offset: Int) async throws -> [String] { [] }
    func findIndexedFiles(query: String, limit: Int) async throws -> [IndexedFileMatch] { [] }
    func readIndexedFile(path: String, startLine: Int?, endLine: Int?) throws -> String { "" }
    func searchIndexedText(pattern: String, limit: Int) async throws -> [String] { [] }
    func searchSymbols(nameLike query: String, limit: Int) async throws -> [Symbol] { [] }
    func searchSymbolsWithPaths(nameLike query: String, limit: Int) async throws -> [SymbolSearchResult] { [] }
    func getSummaries(projectRoot: URL, limit: Int) async throws -> [(path: String, summary: String)] { [] }

    func getStats() async throws -> IndexStats {
        IndexStats(
            indexedResourceCount: 0,
            aiEnrichedResourceCount: 0,
            aiEnrichableProjectFileCount: 0,
            totalProjectFileCount: 0,
            symbolCount: 0,
            classCount: 0,
            structCount: 0,
            enumCount: 0,
            protocolCount: 0,
            functionCount: 0,
            variableCount: 0,
            databaseSizeBytes: 0,
            databasePath: "",
            isDatabaseInWorkspace: false,
            averageQualityScore: 0,
            averageAIQualityScore: 0
        )
    }
}
