import XCTest
@testable import Compass

final class EmbeddingBenchmarkHarnessTests: XCTestCase {
    private static var sourceModelsDir: URL {
        if let envPath = ProcessInfo.processInfo.environment["COMPASS_EMBEDDING_MODELS_DIR"] {
            return URL(fileURLWithPath: envPath)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Compass/Resources/EmbeddingModels")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        // Derive from this file's location: <repo>/CompassHarnessTests → <repo>/Compass/Resources/EmbeddingModels
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let derived = repoRoot
            .appendingPathComponent("Compass/Resources/EmbeddingModels")
        if FileManager.default.fileExists(atPath: derived.path) { return derived }
        return repoRoot.appendingPathComponent("Compass/Resources/EmbeddingModels")
    }

    func test_benchmarkAllModels() async throws {
        let models = discoverModels()
        XCTAssertFalse(models.isEmpty, "No embedding models found in bundle or source")

        var results: [(name: String, dims: Int, sizeMB: Int, avgMs: Double, failed: Bool)] = []

        for model in models {
            let sizeMB = directorySizeMB(model.modelDir)
            Swift.print("\n[EMB-BENCH] === \(model.name) (\(formatSize(sizeMB))) ===")

            guard let vocabURL = model.vocabURL else {
                Swift.print("[EMB-BENCH] ❌ \(model.name): no vocab file, skipping")
                continue
            }

            let gen: CoreMLTextEmbeddingGenerator
            do {
                let loadStart = Date()
                gen = try CoreMLTextEmbeddingGenerator(
                    modelName: model.name,
                    modelURL: model.modelDir,
                    vocabURL: vocabURL
                )
                let loadMs = elapsedMs(loadStart)
                Swift.print("[EMB-BENCH]   Load: \(loadMs)ms")
            } catch {
                Swift.print("[EMB-BENCH] ❌ \(model.name): init failed — \(error.localizedDescription)")
                results.append((model.name, 0, sizeMB, 0, true))
                continue
            }

            let sentences = [
                "how to sort an array in Swift",
                "the quick brown fox jumps over the lazy dog",
                "implement a binary search tree in Python",
                "what is the capital of France",
                "sorting algorithms explained simply"
            ]

            let embedStart = Date()
            var totalMs: Double = 0
            var count = 0
            var lastDim = 0

            for sentence in sentences {
                let callStart = Date()
                do {
                    let vec = try await gen.generateEmbedding(for: sentence)
                    let ms = elapsedMs(callStart)
                    totalMs += Double(ms)
                    count += 1
                    lastDim = vec.count
                    Swift.print("[EMB-BENCH]   \"\(sentence.prefix(40))...\" → \(ms)ms, dim=\(vec.count)")
                } catch {
                    Swift.print("[EMB-BENCH]   \"\(sentence.prefix(40))...\" ❌ \(error.localizedDescription)")
                }
            }

            let avgMs = count > 0 ? totalMs / Double(count) : 0
            let totalEmbedMs = elapsedMs(embedStart)
            Swift.print("[EMB-BENCH] ✅ \(model.name): avg=\(String(format: "%.1f", avgMs))ms, total=\(totalEmbedMs)ms, dim=\(lastDim), size=\(formatSize(sizeMB))")
            results.append((model.name, lastDim, sizeMB, avgMs, false))
        }

        Swift.print("\n[EMB-BENCH] ====== SUMMARY ======")
        Swift.print("[EMB-BENCH] Model                          Dims    Size  Avg(ms)")
        Swift.print("[EMB-BENCH] ------------------------------------------------")
        for r in results {
            if r.failed {
                Swift.print("[EMB-BENCH] \(padRight(r.name, 30)) ❌ FAILED")
            } else {
                Swift.print("[EMB-BENCH] \(padRight(r.name, 30)) \(padLeft(r.dims, 4))d \(padLeft(r.sizeMB, 5))MB \(padLeft(Int(r.avgMs), 7))ms")
            }
        }

        // Model must be usable (avg < 100ms per embedding)
        let usable = results.filter { !$0.failed && $0.avgMs < 100 }
        XCTAssertFalse(usable.isEmpty, "At least one embedding model must be usable (avg < 100ms)")
    }

    private struct DiscoveredModel {
        let name: String
        let modelDir: URL
        let vocabURL: URL?
    }

    private func discoverModels() -> [DiscoveredModel] {
        guard FileManager.default.fileExists(atPath: Self.sourceModelsDir.path) else {
            Swift.print("[EMB-BENCH] Model directory not found at \(Self.sourceModelsDir.path)")
            return []
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: Self.sourceModelsDir.path) else { return [] }

        let dirs = contents.filter { $0.hasSuffix(".mlmodelc") }.sorted()
        return dirs.map { name in
            let baseName = String(name.dropLast(".mlmodelc".count))
            let vocabURL = Self.sourceModelsDir.appendingPathComponent("\(baseName).vocab.txt")
            return DiscoveredModel(
                name: baseName,
                modelDir: Self.sourceModelsDir.appendingPathComponent(name),
                vocabURL: FileManager.default.fileExists(atPath: vocabURL.path) ? vocabURL : nil
            )
        }
    }

    private func directorySizeMB(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int64 else { continue }
            total += size
        }
        return Int(total / 1_048_576)
    }

    private func formatSize(_ mb: Int) -> String {
        mb >= 100 ? "\(mb)" : "\(mb)"
    }
}

private func elapsedMs(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

private func padRight(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

private func padLeft(_ v: Int, _ n: Int) -> String {
    let s = "\(v)"
    return s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
