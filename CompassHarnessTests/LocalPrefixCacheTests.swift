import XCTest
import Foundation
@testable import Compass

/// System-prefix KV disk cache: conversation A builds the prefix cache (in
/// the background after generation); a NEW conversation in the same project
/// must load it and prefill only the user message (fast, small promptTokens).
@MainActor
final class LocalPrefixCacheTests: XCTestCase {

    func testNewConversationReusesDiskPrefixCache() async throws {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded")
        }
        let runtime = try await HarnessRuntime.makeRuntime()
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        runtime.manager.currentMode = .chat

        // Conversation A — builds the prefix cache in the background.
        let okA = try await HarnessRuntime.sendAndWait(
            "hi", manager: runtime.manager, timeout: 300)
        print("[PREFIX-CACHE] conversation A ok=\(okA)")
        XCTAssertTrue(okA)

        // Wait for the background prefix build + save.
        let cacheDir = runtime.projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        var prefixFile: URL?
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, prefixFile == nil {
            prefixFile = (try? FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?.first { $0.lastPathComponent.hasPrefix("kv-prefix-") }
            if prefixFile == nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        guard let prefixFile else {
            XCTFail("Prefix cache file was never written to \(cacheDir.path)")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: prefixFile.path)[.size] as? Int) ?? 0
        print("[PREFIX-CACHE] file written: \(prefixFile.lastPathComponent) \(size / 1024)KB")

        // Conversation B — fresh conversation, same project: must load the prefix.
        let traceBase = Self.traceLineCount(runtime.projectRoot)
        runtime.manager.startNewConversation()
        let okB = try await HarnessRuntime.sendAndWait(
            "what is 2 + 2? answer in one word", manager: runtime.manager, timeout: 300)
        print("[PREFIX-CACHE] conversation B ok=\(okB)")
        XCTAssertTrue(okB)

        let trace = Self.lastGenerateComplete(runtime.projectRoot, sinceLine: traceBase)
        let promptTokens = trace["promptTokens"] as? Int ?? Int.max
        let prefillMs = trace["promptMs"] as? Int ?? Int.max
        print("[PREFIX-CACHE] B promptTokens=\(promptTokens) prefillMs=\(prefillMs)")
        XCTAssertLessThan(
            promptTokens, 500,
            "Conversation B should prefill only the user message (~tens of tokens), got \(promptTokens)"
        )
        XCTAssertLessThan(prefillMs, 5_000, "Conversation B prefill should be fast, got \(prefillMs)ms")

        let answer = runtime.manager.messages
            .filter { $0.role == .assistant && !$0.isDraft }
            .last?.content ?? ""
        print("[PREFIX-CACHE] B answer: \(String(answer.prefix(60)))")
        XCTAssertFalse(answer.isEmpty)
    }

    private static func traceLineCount(_ projectRoot: URL) -> Int {
        let url = projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ai-trace.ndjson")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func lastGenerateComplete(_ projectRoot: URL, sinceLine: Int) -> [String: Any] {
        let url = projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ai-trace.ndjson")
        let deadline = Date().addingTimeInterval(3)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.split(separator: "\n").count > sinceLine { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var latest: [String: Any] = [:]
        for (index, line) in text.split(separator: "\n").enumerated() where index >= sinceLine {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "mlx.generate_complete" else { continue }
            latest = obj
        }
        return latest
    }
}
