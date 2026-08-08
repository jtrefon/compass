import XCTest
import Foundation
@testable import Compass

/// Local chat benchmark — KPI collection for the Qwen3.5-4B local path.
///
/// Knobs: live `COMPASS_LOCAL_MODEL_*` env vars (mirroring fim-bench.conf).
/// Control: `LOCAL_BENCH_ITERATIONS` (default 1), `LOCAL_BENCH_TASKS`
/// (comma-separated task-id filter).
///
/// Output: NDJSON per task-run in `<root>/.ide/logs/local-bench.ndjson` plus
/// a `[LOCAL-BENCH]` console table. Spec: Documentation/LocalInference_Benchmark.md
@MainActor
final class LocalBenchmarkHarnessTests: XCTestCase {

    // MARK: - KPI row

    struct BenchRow {
        var taskId: String
        var iteration: Int
        var configLabel: String
        var answer: String = ""
        // performance
        var loadMs: Int = 0
        var prefillMs: Int = 0
        var prefillTokens: Int = 0
        var prefillTps: Double = 0
        var generationTps: Double = 0
        var totalMs: Int = 0
        var generationTokens: Int = 0
        // resource (GPU — MLX active/peak; process RSS excludes Metal memory)
        var activeMB: Int = 0
        var peakMB: Int = 0
        var processRSSMB: Int = 0
        // quality
        var similarity: Double = 0
        var completeness: Double = 0
        var verbosityRatio: Double = 0
        // agentic compliance
        var validToolCall: Bool = false
        var schemaAdherent: Bool = false
        var correctTool: Bool = false
        var malformedMarkup: Bool = false
    }

    // MARK: - Run

    func testLocalBenchmarkMatrix() async throws {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded — benchmark skipped")
        }
        let env = ProcessInfo.processInfo.environment
        let conf = Self.readBenchConf()
        func envOrPrefixed(_ key: String) -> String? {
            env[key] ?? env["TEST_RUNNER_ENV_\(key)"] ?? conf[key]
        }
        let iterations = envOrPrefixed("LOCAL_BENCH_ITERATIONS").flatMap(Int.init) ?? 1
        let filter = envOrPrefixed("LOCAL_BENCH_TASKS")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let tasks = LocalBenchFixtures.all.filter { filter.isEmpty || filter.contains($0.id) }

        let runtime = try await HarnessRuntime.makeRuntime()
        let store = LocalModelSelectionStore(settingsStore: runtime.container.settingsStore)
        await store.setOfflineModeEnabled(true)
        runtime.manager.currentMode = .chat

        let configLabel = Self.configLabel()
        var rows: [BenchRow] = []

        for iteration in 1...iterations {
            for task in tasks {
                // Fresh conversation per task so KPIs map 1:1 to the task.
                runtime.manager.startNewConversation()
                let traceBase = Self.traceLineCount(runtime.projectRoot)
                let prompt = (task.context.map { "Context:\n\($0)\n\n" } ?? "") + task.prompt
                let start = ContinuousClock.now
                _ = try await HarnessRuntime.sendAndWait(prompt, manager: runtime.manager, timeout: 300)
                let wallMs = Self.milliseconds(start.duration(to: .now))

                let assistantMessages = runtime.manager.messages
                    .filter { $0.role == .assistant && !$0.isDraft }
                let answer = assistantMessages.last?.content ?? ""
                let toolCall = assistantMessages
                    .compactMap(\.toolCalls)
                    .flatMap { $0 }
                    .first
                if let toolCall {
                    Self.committedToolCall = ParsedCall(name: toolCall.name, arguments: toolCall.arguments)
                } else {
                    Self.committedToolCall = nil
                }
                let trace = try Self.readTrace(runtime.projectRoot, sinceLine: traceBase)
                var row = BenchRow(
                    taskId: task.id,
                    iteration: iteration,
                    configLabel: configLabel,
                    answer: answer
                )
                Self.applyTrace(trace, to: &row)
                Self.applyQuality(answer: answer, task: task, to: &row)
                Self.applyCompliance(answer: answer, task: task, to: &row)
                if row.totalMs == 0 { row.totalMs = wallMs }
                rows.append(row)

                Self.writeRow(row, projectRoot: runtime.projectRoot)
                print("[LOCAL-BENCH] \(task.id) iter=\(iteration) gen=\(String(format: "%.1f", row.generationTps))tps prefill=\(String(format: "%.0f", row.prefillTps))tok/s(\(row.prefillMs)ms) gpu=\(row.peakMB)MB sim=\(String(format: "%.2f", row.similarity)) comp=\(String(format: "%.0f", row.completeness * 100))% tool=\(row.validToolCall ? row.correctTool ? "ok" : "wrong" : "none")")
            }
        }

        Self.printSummary(rows)
    }

    // MARK: - KPI collection

    private static func applyTrace(_ trace: [String: Any], to row: inout BenchRow) {
        row.loadMs = trace["loadMs"] as? Int ?? 0
        row.prefillMs = trace["promptMs"] as? Int ?? 0
        row.prefillTokens = trace["promptTokens"] as? Int ?? 0
        row.prefillTps = trace["promptTokensPerSecond"] as? Double ?? 0
        row.generationTps = trace["generationTokensPerSecond"] as? Double ?? 0
        row.totalMs = trace["totalMs"] as? Int ?? 0
        row.generationTokens = trace["generationTokens"] as? Int ?? 0
        row.processRSSMB = trace["rssAfterGenMB"] as? Int ?? 0
        row.activeMB = trace["activeMB"] as? Int ?? 0
        row.peakMB = trace["peakMB"] as? Int ?? 0
    }

    private static func applyQuality(answer: String, task: LocalBenchTask, to row: inout BenchRow) {
        row.similarity = cosine(HashEmbed.embed(answer), HashEmbed.embed(task.golden))
        let lower = answer.lowercased()
        let hits = task.checklist.filter { lower.contains($0.lowercased()) }.count
        row.completeness = task.checklist.isEmpty ? 0 : Double(hits) / Double(task.checklist.count)
        let goldenTokens = max(1, task.golden.split(separator: " ").count)
        let answerTokens = max(0, answer.split(separator: " ").count)
        row.verbosityRatio = Double(answerTokens) / Double(goldenTokens)
    }

    private static func applyCompliance(answer: String, task: LocalBenchTask, to row: inout BenchRow) {
        guard task.expectsToolCall else { return }
        // The committed tool-call message carries the structured calls (the
        // pass-1 message); the final answer is pass-2 text. Prefer the
        // committed toolCalls over parsing the answer text.
        if let call = committedToolCall,
           let args = call.arguments as? [String: Any] {
            row.validToolCall = true
            row.schemaAdherent = !args.isEmpty
            row.correctTool = (call.name == task.expectedToolName) && row.schemaAdherent
        }
        row.malformedMarkup = ToolMarkupStripper.containsToolCallMarkup(answer) && !row.validToolCall
    }

    // MARK: - Trace reading

    /// The trace logger writes asynchronously — poll until the row count
    /// grows past `sinceLine` before parsing, so the read never races the
    /// flush (stale rows made prefill KPIs wrong).
    private static func readTrace(_ projectRoot: URL, sinceLine: Int) throws -> [String: Any] {
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
        var memory: [String: Any] = [:]
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard index >= sinceLine,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "mlx.generate_complete":
                latest = obj
            case "mlx.memory_snapshot":
                memory = obj
            default:
                break
            }
        }
        latest["activeMB"] = memory["activeMB"] ?? 0
        latest["peakMB"] = memory["peakMB"] ?? 0
        return latest
    }

    private static func traceLineCount(_ projectRoot: URL) -> Int {
        let url = projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ai-trace.ndjson")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func readBenchConf() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let profileDir = env["COMPASS_TEST_PROFILE_DIR"]
            ?? (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/compass-test-profile-path"),
                encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileDir,
              let text = try? String(contentsOf: URL(fileURLWithPath: profileDir).appendingPathComponent("local-bench.conf"), encoding: .utf8) else {
            return [:]
        }
        var conf: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                conf[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return conf
    }

    // MARK: - Tool-call parsing

    /// Latest committed tool call from the current run (populated per task).
    private static var committedToolCall: ParsedCall?

    private struct ParsedCall {
        let name: String
        let arguments: Any?
    }

    private static func parseToolCall(from answer: String) -> ParsedCall? {
        guard let start = answer.range(of: "<tool_call>"),
              let end = answer.range(of: "</tool_call>") else { return nil }
        let json = answer[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        return ParsedCall(name: name, arguments: obj["arguments"])
    }

    // MARK: - Deterministic hashed n-gram embedding (quality proxy)

    enum HashEmbed {
        static let dim = 512

        static func embed(_ text: String) -> [Float] {
            var vec = [Float](repeating: 0, count: dim)
            let lowered = text.lowercased()
            let grams: [Substring] = lowered.isEmpty
                ? []
                : (0...max(0, lowered.count - 2)).flatMap { i -> [Substring] in
                    let start = lowered.index(lowered.startIndex, offsetBy: i)
                    let end2 = lowered.index(start, offsetBy: 2, limitedBy: lowered.endIndex) ?? lowered.endIndex
                    let end3 = lowered.index(start, offsetBy: 3, limitedBy: lowered.endIndex) ?? lowered.endIndex
                    return [lowered[start..<end2], lowered[start..<end3]]
                }
            for gram in grams {
                var h: UInt64 = 1469598103934665603
                for byte in gram.utf8 {
                    h ^= UInt64(byte)
                    h &*= 1099511628211
                }
                let idx = Int(h % UInt64(dim))
                vec[idx] += 1
            }
            let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { vec = vec.map { $0 / norm } }
            return vec
        }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, a.count > 0 else { return 0 }
        var dot: Double = 0
        for i in a.indices { dot += Double(a[i] * b[i]) }
        return dot
    }

    // MARK: - Output

    private static func configLabel() -> String {
        let env = ProcessInfo.processInfo.environment
        var conf: [String: String] = [:]
        let profileDir = env["COMPASS_TEST_PROFILE_DIR"]
            ?? (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/compass-test-profile-path"),
                encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profileDir,
           let text = try? String(
             contentsOf: URL(fileURLWithPath: profileDir).appendingPathComponent("local-bench.conf"),
             encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    conf[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        func knob(_ key: String) -> String? { env[key] ?? conf[key] }
        let parts = [
            knob("COMPASS_LOCAL_MODEL_TEMPERATURE").map { "t=\($0)" },
            knob("COMPASS_LOCAL_MODEL_TOP_P").map { "top=\($0)" },
            knob("COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE").map { "pf=\($0)" },
            knob("COMPASS_LOCAL_MODEL_MAX_KV_SIZE").map { "kv=\($0)" },
            knob("COMPASS_LOCAL_MODEL_KV_CACHE_4BIT").map { "kv4bit=\($0)" },
            knob("COMPASS_LOCAL_MODEL_CONTEXT_LENGTH").map { "ctx=\($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? "default" : parts.joined(separator: ",")
    }

    private static func writeRow(_ row: BenchRow, projectRoot: URL) {
        let logsDir = projectRoot.appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("local-bench.ndjson")
        var payload: [String: Any] = [
            "taskId": row.taskId,
            "iteration": row.iteration,
            "config": row.configLabel,
            "loadMs": row.loadMs,
            "prefillMs": row.prefillMs,
            "prefillTokens": row.prefillTokens,
            "generationTokensPerSecond": row.generationTps,
            "generationTokens": row.generationTokens,
            "totalMs": row.totalMs,
            "processRSSMB": row.processRSSMB,
            "activeMB": row.activeMB,
            "peakMB": row.peakMB,
            "similarity": row.similarity,
            "completeness": row.completeness,
            "verbosityRatio": row.verbosityRatio,
            "validToolCall": row.validToolCall,
            "schemaAdherent": row.schemaAdherent,
            "correctTool": row.correctTool,
            "malformedMarkup": row.malformedMarkup,
            "answer": row.answer,
        ]
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            var line = data
            line.append(0x0A)
            try? FileHandle(forWritingTo: url).seekToEndOfFile()
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: url.path, contents: line)
            }
        }
    }

    private static func printSummary(_ rows: [BenchRow]) {
        guard !rows.isEmpty else { return }
        let tps = rows.map(\.generationTps).reduce(0, +) / Double(rows.count)
        let prefillMsAvg = rows.map(\.prefillMs).reduce(0, +) / rows.count
        let prefillTps = rows.map(\.prefillTps).reduce(0, +) / Double(rows.count)
        let sim = rows.map(\.similarity).reduce(0, +) / Double(rows.count)
        let comp = rows.map(\.completeness).reduce(0, +) / Double(rows.count)
        let toolRows = rows.filter { $0.validToolCall }
        let correct = toolRows.filter(\.correctTool).count
        let malformed = rows.filter(\.malformedMarkup).count
        let avgPeak = rows.map(\.peakMB).reduce(0, +) / rows.count
        print("[LOCAL-BENCH] SUMMARY config=\(rows.first?.configLabel ?? "?") tasks=\(rows.count)")
        print("[LOCAL-BENCH]   gen tps=\(String(format: "%.1f", tps)) prefill=\(String(format: "%.0f", prefillTps))tok/s (avg \(prefillMsAvg)ms) gpuPeak=\(avgPeak)MB")
        print("[LOCAL-BENCH]   similarity=\(String(format: "%.2f", sim)) completeness=\(String(format: "%.0f", comp * 100))%")
        print("[LOCAL-BENCH]   tool calls=\(toolRows.count) correct=\(correct) malformed=\(malformed)")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
