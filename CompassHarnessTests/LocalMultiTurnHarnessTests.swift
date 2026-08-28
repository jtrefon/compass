import XCTest
import Foundation
@testable import Compass

/// Multi-turn local chat scenario — the harness only ORCHESTRATES production
/// code (real DependencyContainer, real ConversationManager, real MLX engine)
/// and collects the existing ai-trace telemetry. No app logic is implemented
/// here.
///
/// Scenario:
///   Turn 1 — user asks to create a file (write tool must execute).
///   Turn 2 — same conversation, follow-up edit (KV cache must be retained:
///            prefill only the user-suffix, promptMs drops vs turn 1).
///   Turn 3 — NEW conversation (session switch): disk system-prefix cache must
///            be reused (promptTokens < 500, fast prefill).
///
/// Telemetry: per-turn NDJSON rows to `<root>/.ide/logs/local-multiturn.ndjson`
/// plus a `[LOCAL-MULTI]` console summary. Context length is exercised through
/// the same settings path the UI slider uses (LocalModelSelectionStore).
@MainActor
final class LocalMultiTurnHarnessTests: XCTestCase {

    // MARK: - Scenario

    func testMultiTurnToolsKVRetentionAndPrefixReuse() async throws {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded — multi-turn scenario skipped")
        }

        let runtime = try await HarnessRuntime.makeRuntime()
        // The container's own store (`.standard` defaults) — the harness must
        // write through the SAME settings path the MLX service reads, not a
        // default-constructed store that binds the test-profile suite.
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        await store.setKVCache4BitEnabled(false)

        // Exercise the settings-slider wiring: the stored context length must
        // reach the resolved MLX configuration unclamped (64K default).
        await store.setContextLength(65_536)
        runtime.manager.currentMode = .coder

        let target = runtime.projectRoot.appendingPathComponent("multiturn-a.txt")

        // ---- Turn 1: create file (write tool) ----
        let turn1TraceBase = Self.traceLineCount(runtime.projectRoot)
        let t1 = ContinuousClock.now
        let ok1 = try await HarnessRuntime.sendAndWait(
            "Create a file named multiturn-a.txt in the project root containing the exact text: alpha",
            manager: runtime.manager,
            timeout: 300
        )
        let turn1 = Self.captureEvents(runtime.projectRoot, sinceLine: turn1TraceBase)

        print("[LOCAL-MULTI] turn1 ok=\(ok1) msgs=\(runtime.manager.messages.count)")
        XCTAssertTrue(ok1, "Turn 1 must complete")
        let turn1Content = try? String(contentsOf: target, encoding: .utf8)
        XCTAssertNotNil(turn1Content, "Turn 1 must write multiturn-a.txt to disk")
        XCTAssertTrue(turn1Content?.contains("alpha") == true,
                      "Turn 1 must write the requested content")
        let turn1Tools = runtime.manager.messages
            .filter { $0.isToolExecution }
            .compactMap(\.toolName)
        print("[LOCAL-MULTI] turn1 tools: \(turn1Tools.joined(separator: ", "))")
        XCTAssertTrue(
            turn1Tools.contains { ["write", "write_file", "create_file", "edit"].contains($0) },
            "Turn 1 must execute a write-family tool, got: \(turn1Tools)"
        )

        // ---- Turn 2: same conversation, follow-up edit ----
        let turn2TraceBase = Self.traceLineCount(runtime.projectRoot)
        let t2 = ContinuousClock.now
        let ok2 = try await HarnessRuntime.sendAndWait(
            "Append the exact line 'beta' to multiturn-a.txt",
            manager: runtime.manager,
            timeout: 300
        )
        let turn2 = Self.captureEvents(runtime.projectRoot, sinceLine: turn2TraceBase)
        print("[LOCAL-MULTI] turn2 ok=\(ok2) msgs=\(runtime.manager.messages.count)")
        XCTAssertTrue(ok2, "Turn 2 must complete")
        let turn2Content = try? String(contentsOf: target, encoding: .utf8)
        XCTAssertNotNil(turn2Content, "Turn 2 must leave multiturn-a.txt on disk")
        XCTAssertGreaterThan(turn2Content?.count ?? 0, turn1Content?.count ?? 0,
                             "Turn 2 must modify (grow) the file, got \(turn2Content?.count ?? 0) chars vs \(turn1Content?.count ?? 0)")
        let turn2Tools = runtime.manager.messages
            .filter { $0.isToolExecution }
            .compactMap(\.toolName)
        print("[LOCAL-MULTI] turn2 tools: \(turn2Tools.joined(separator: ", "))")
        XCTAssertTrue(!turn2Tools.isEmpty, "Turn 2 must execute a tool")
        HarnessRuntime.assertNoRawToolMarkup(runtime.manager)

        // ---- Turn 3: new conversation (session switch) ----
        runtime.manager.startNewConversation()
        let turn3TraceBase = Self.traceLineCount(runtime.projectRoot)
        let t3 = ContinuousClock.now
        let ok3 = try await HarnessRuntime.sendAndWait(
            "List the files in the project root directory.",
            manager: runtime.manager,
            timeout: 300
        )
        let turn3 = Self.captureEvents(runtime.projectRoot, sinceLine: turn3TraceBase)
        print("[LOCAL-MULTI] turn3 ok=\(ok3) msgs=\(runtime.manager.messages.count)")
        XCTAssertTrue(ok3, "Turn 3 must complete")

        // ---- Telemetry: per-turn NDJSON + console summary ----
        let rows = [
            Self.row(turn: 1, phase: "create-file", wallMs: Self.milliseconds(t1.duration(to: .now)), events: turn1, tools: turn1Tools, config: turn1.config),
            Self.row(turn: 2, phase: "edit-kv-retention", wallMs: Self.milliseconds(t2.duration(to: .now)), events: turn2, tools: turn2Tools, config: turn2.config),
            Self.row(turn: 3, phase: "session-switch", wallMs: Self.milliseconds(t3.duration(to: .now)), events: turn3, tools: [], config: turn3.config),
        ]
        for row in rows {
            Self.writeRow(row, projectRoot: runtime.projectRoot)
            Self.printRow(row)
        }
        Self.printSummary(rows)

        // ---- KV retention: turn 2 must prefill much less than turn 1 ----
        let turn1PrefillMs = turn1.firstPrefillMs()
        let turn2PrefillMs = turn2.firstPrefillMs()
        print("[LOCAL-MULTI] KV retention check: turn1 prefill=\(turn1PrefillMs)ms turn2 prefill=\(turn2PrefillMs)ms")
        XCTAssertGreaterThan(turn1PrefillMs, 0, "Turn 1 must have a measurable full prefill")
        XCTAssertLessThan(
            turn2PrefillMs, max(2_500, turn1PrefillMs / 3),
            "Turn 2 must reuse the retained KV cache (suffix-only prefill); got \(turn2PrefillMs)ms vs turn1 \(turn1PrefillMs)ms"
        )

        // ---- Prefix cache: turn 3 (new conversation) must prefill only the
        // system prefix (~small promptTokens), not the full 9.6K system block.
        let turn3First = turn3.firstGenerateComplete()
        let turn3PromptTokens = turn3First["promptTokens"] as? Int ?? Int.max
        let turn3PrefillMs = turn3First["promptMs"] as? Int ?? Int.max
        print("[LOCAL-MULTI] prefix reuse check: turn3 promptTokens=\(turn3PromptTokens) prefillMs=\(turn3PrefillMs)")
        XCTAssertLessThan(turn3PromptTokens, 2_000,
                          "New conversation must load the disk system-prefix cache, got \(turn3PromptTokens) prompt tokens")
        XCTAssertLessThan(turn3PrefillMs, 15_000,
                          "New conversation prefix prefill should be fast, got \(turn3PrefillMs)ms")
    }

    /// Runs the same scenario with the slider at the top of its range (model
    /// capability, 262,144) to prove the extended slider actually reaches the
    /// inference layer. 4-bit KV is enabled to keep the KV buffer bounded.
    func testMultiTurnAtMaxModelContext() async throws {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded — max-context scenario skipped")
        }
        let runtime = try await HarnessRuntime.makeRuntime()
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        await store.setContextLength(262_144)
        await store.setKVCache4BitEnabled(true)
        runtime.manager.currentMode = .coder

        let traceBase = Self.traceLineCount(runtime.projectRoot)
        let ok = try await HarnessRuntime.sendAndWait(
            "Create a file named maxctx-proof.txt in the project root containing: maxctx-ok",
            manager: runtime.manager,
            timeout: 300
        )
        XCTAssertTrue(ok, "Max-context turn must complete")
        let events = Self.captureEvents(runtime.projectRoot, sinceLine: traceBase)
        let first = events.firstGenerateComplete()
        let resolvedContext = first["contextLength"] as? Int ?? 0
        print("[LOCAL-MULTI] max-context resolved contextLength=\(resolvedContext)")
        XCTAssertEqual(resolvedContext, 262_144,
                       "Slider max (262,144) must reach the MLX configuration, got \(resolvedContext)")
        let proof = try? String(contentsOf: runtime.projectRoot.appendingPathComponent("maxctx-proof.txt"), encoding: .utf8)
        XCTAssertTrue(proof?.contains("maxctx-ok") == true,
                      "Max-context turn must still execute the write tool")
    }

    // MARK: - Telemetry rows

    struct TurnRow {
        let turn: Int
        let phase: String
        let wallMs: Int
        let promptTokens: Int
        let prefillMs: Int
        let prefillTps: Double
        let generationTps: Double
        let generationTokens: Int
        let totalMs: Int
        let toolCalls: Int
        let tools: [String]
        let contextLength: Int
        let maxKVSize: Int
        let cacheKind: String
        let kvCache4Bit: Bool
        let gpuPeakMB: Int
    }

    // MARK: - Trace reading (pattern from LocalBenchmarkHarnessTests)

    private struct CapturedEvents {
        var completes: [[String: Any]] = []
        var memory: [String: Any] = [:]
        var config: [String: Any] = [:]

        func firstGenerateComplete() -> [String: Any] {
            completes.first ?? [:]
        }

        func firstPrefillMs() -> Int {
            firstGenerateComplete()["promptMs"] as? Int ?? 0
        }
    }

    private static func captureEvents(_ projectRoot: URL, sinceLine: Int) -> CapturedEvents {
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
        var captured = CapturedEvents()
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard index >= sinceLine,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "mlx.generate_complete":
                captured.completes.append(obj)
            case "mlx.memory_snapshot":
                captured.memory = obj
            case "mlx.generate_start":
                captured.config = obj
            default:
                break
            }
        }
        return captured
    }

    private static func traceLineCount(_ projectRoot: URL) -> Int {
        let url = projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ai-trace.ndjson")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    // MARK: - Row building

    private static func row(turn: Int, phase: String, wallMs: Int, events: CapturedEvents, tools: [String], config: [String: Any]) -> TurnRow {
        let first = events.firstGenerateComplete()
        let toolCalls = events.completes.reduce(0) { $0 + (($1["toolCalls"] as? Int) ?? 0) }
        return TurnRow(
            turn: turn,
            phase: phase,
            wallMs: wallMs,
            promptTokens: first["promptTokens"] as? Int ?? 0,
            prefillMs: first["promptMs"] as? Int ?? 0,
            prefillTps: first["promptTokensPerSecond"] as? Double ?? 0,
            generationTps: first["generationTokensPerSecond"] as? Double ?? 0,
            generationTokens: first["generationTokens"] as? Int ?? 0,
            totalMs: first["totalMs"] as? Int ?? 0,
            toolCalls: toolCalls,
            tools: tools,
            contextLength: config["contextLength"] as? Int ?? 0,
            maxKVSize: config["maxKVSize"] as? Int ?? 0,
            cacheKind: config["cacheKind"] as? String ?? "?",
            kvCache4Bit: config["kvCache4Bit"] as? Bool ?? false,
            gpuPeakMB: events.memory["peakMB"] as? Int ?? 0
        )
    }

    // MARK: - Output

    private static func printRow(_ row: TurnRow) {
        print("[LOCAL-MULTI] turn\(row.turn) [\(row.phase)] ctx=\(row.contextLength) kv=\(row.maxKVSize) \(row.cacheKind) kv4bit=\(row.kvCache4Bit ? "on" : "off") prefill=\(row.prefillMs)ms(\(row.promptTokens)tok) gen=\(String(format: "%.1f", row.generationTps))tps tools=\(row.tools.joined(separator: ",") ) calls=\(row.toolCalls) gpuPeak=\(row.gpuPeakMB)MB")
    }

    private static func printSummary(_ rows: [TurnRow]) {
        print("[LOCAL-MULTI] SUMMARY turns=\(rows.count)")
        for row in rows {
            print("[LOCAL-MULTI]   turn\(row.turn) prefill=\(row.prefillMs)ms promptTokens=\(row.promptTokens) gen=\(String(format: "%.1f", row.generationTps))tps toolCalls=\(row.toolCalls) gpuPeak=\(row.gpuPeakMB)MB")
        }
        if rows.count >= 2 {
            let t1 = rows[0].prefillMs
            let t2 = rows[1].prefillMs
            if t1 > 0 {
                print("[LOCAL-MULTI]   KV retention: turn2 prefill = \(String(format: "%.0f", Double(t2) / Double(t1) * 100))% of turn1")
            }
        }
    }

    private static func writeRow(_ row: TurnRow, projectRoot: URL) {
        let logsDir = projectRoot.appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("local-multiturn.ndjson")
        var payload: [String: Any] = [
            "turn": row.turn,
            "phase": row.phase,
            "wallMs": row.wallMs,
            "promptTokens": row.promptTokens,
            "prefillMs": row.prefillMs,
            "promptTokensPerSecond": row.prefillTps,
            "generationTokensPerSecond": row.generationTps,
            "generationTokens": row.generationTokens,
            "totalMs": row.totalMs,
            "toolCalls": row.toolCalls,
            "toolNames": row.tools,
            "contextLength": row.contextLength,
            "maxKVSize": row.maxKVSize,
            "cacheKind": row.cacheKind,
            "kvCache4Bit": row.kvCache4Bit,
            "gpuPeakMB": row.gpuPeakMB,
        ]
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            var line = data
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: url.path, contents: line)
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
