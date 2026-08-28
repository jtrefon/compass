import XCTest
import Darwin
@testable import Compass

/// [BENCH] Core performance metrics — measured on real app code, not marketing.
///
/// These are the numbers the website promises:
///   - RAM footprint & growth (the founding story: "Cursor + Docker ate my 16GB")
///   - Vector store add throughput + search latency (HNSW via the real FAISS bridge)
///   - Multi-file read (editor open-path proxy)
///
/// Output: [BENCH] human-readable lines + JSON at COMPASS_BENCH_OUTPUT
/// (default: .build-tests/benchmarks/latest.json).
///
/// Run via: ./run.sh benchmark
@MainActor
final class BenchmarkMetricsTests: XCTestCase {

    // MARK: - Process RAM

    func test_benchmarkRAMAndVectorStore() async throws {
        var metrics: [String: Double] = [:]

        let baselineMB = physFootprintMB()
        bench("ram.baseline_mb", baselineMB, metrics: &metrics)

        // --- Real vector store: FAISS HNSW, 64-dim, 2000 entries ---
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench_metrics_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = VectorStoreConfiguration(
            storePath: root.appendingPathComponent("vector_store"),
            dimensions: 64,
            factoryString: "IDMap,HNSW32"
        )
        let store = VectorStoreService.create(with: config)

        let tLoad = Date()
        try await store.load()
        bench("vector.store_load_ms", elapsedMs(tLoad), metrics: &metrics)

        let entries: [(text: String, vector: [Float])] =
            (0..<2000).map { i in
                (
                    text: "benchmark chunk \(i): the navigation bar uses a custom NSToolbarItem " +
                          "and session restore persists open editor tabs across launches",
                    vector: BenchmarkMetricsTests.deterministicVector(seed: i, dims: 64)
                )
            }

        let tAdd = Date()
        for entry in entries {
            _ = try await store.addEntry(text: entry.text, vector: entry.vector, source: "bench")
        }
        let addMs = elapsedMs(tAdd)
        bench("vector.add_2000_ms", addMs, metrics: &metrics)
        bench("vector.add_per_entry_ms", addMs / 2000, metrics: &metrics)

        var searchTimes: [Double] = []
        for i in 0..<50 {
            let query = "benchmark chunk \((i * 37) % 2000)"
            let t = Date()
            let seed = BenchmarkMetricsTests.hashOf(query)
            _ = try await store.searchByText(query: query, embeddingGenerator: { q in
                BenchmarkMetricsTests.deterministicVector(seed: seed, dims: 64)
            }, limit: 10)
            searchTimes.append(elapsedMs(t))
        }
        bench("vector.search_p50_ms", percentile(searchTimes, 50), metrics: &metrics)
        bench("vector.search_p95_ms", percentile(searchTimes, 95), metrics: &metrics)
        bench("vector.search_max_ms", searchTimes.max() ?? 0, metrics: &metrics)

        let afterStoreMB = physFootprintMB()
        bench("ram.after_2000_vectors_mb", afterStoreMB, metrics: &metrics)
        bench("ram.vector_store_growth_mb", afterStoreMB - baselineMB, metrics: &metrics)

        // --- Multi-file read (editor open-path proxy) ---
        let filesDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        for i in 0..<300 {
            let file = filesDir.appendingPathComponent("file_\(i).swift")
            try ("import Foundation\nlet value\(i) = \(i)\n".data(using: .utf8))?.write(to: file)
        }

        let tRead = Date()
        var bytes = 0
        for i in 0..<300 {
            let data = try Data(contentsOf: filesDir.appendingPathComponent("file_\(i).swift"))
            bytes += data.count
        }
        let readMs = elapsedMs(tRead)
        bench("file.read_300_files_ms", readMs, metrics: &metrics)
        bench("file.read_per_file_ms", readMs / 300, metrics: &metrics)

        // --- Sanity thresholds (generous; real regressions surface as deltas in CI) ---
        XCTAssertLessThan(addMs, 30_000, "Batch add of 2000 vectors should take <30s")
        XCTAssertLessThan(percentile(searchTimes, 95), 500, "HNSW search p95 should be <500ms")
        XCTAssertTrue(bytes > 0)

        writeJSON(metrics)
    }

    // MARK: - Helpers

    private func bench(_ name: String, _ value: Double, metrics: inout [String: Double]) {
        metrics[name] = value
        let padded = name.padding(toLength: 32, withPad: " ", startingAt: 0)
        Swift.print("[BENCH] \(padded) \(String(format: "%.2f", value))")
    }

    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    nonisolated private static func deterministicVector(seed: Int, dims: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        var s = UInt64(seed) &* 0x9E3779B97F4A7C15 &+ 0x1234_5678_9ABC_DEF0
        for i in 0..<dims {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            v[i] = Float((s >> 33) & 0xFFFF) / 65535.0 - 0.5
        }
        return v
    }

    nonisolated private static func hashOf(_ text: String) -> Int {
        var h: UInt64 = 5381
        for byte in text.utf8 {
            h = (h &* 33) &+ UInt64(byte)
        }
        return Int(h & 0x7FFF_FFFF)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p / 100).rounded())
        return sorted[min(idx, sorted.count - 1)]
    }

    private func elapsedMs(_ start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }

    private func writeJSON(_ metrics: [String: Double]) {
        let outPath = ProcessInfo.processInfo.environment["COMPASS_BENCH_OUTPUT"]
            ?? FileManager.default.currentDirectoryPath + "/.build-tests/benchmarks/latest.json"
        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "schema": "compass-benchmark-v1",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "host": "\(SysctlHostName() ?? "unknown")",
            "metrics": metrics,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Swift.print("[BENCH] JSON written to \(outPath)")
        }
    }

    private func SysctlHostName() -> String? {
        var size = 0
        sysctlbyname("kern.hostname", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.hostname", &name, &size, nil, 0)
        return String(cString: name)
    }
}
