import Foundation

private func elapsedMs(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

public enum MemoryEmbeddingGeneratorFactory {
    public static func makeBestAvailable() -> MemoryEmbeddingGenerating? {
        let models = discoverModels()
        for model in models {
            let sizeMB = modelSizeMB(model.modelURL)
            let loadStart = Date()
            do {
                let generator = try CoreMLTextEmbeddingGenerator(
                    modelName: model.name,
                    modelURL: model.modelURL,
                    vocabURL: model.vocabURL
                )
                return generator
            } catch {
                continue
            }
        }
        return nil
    }

    public static func makeGenerator(modelName: String) -> MemoryEmbeddingGenerating? {
        guard let model = discoverModels().first(where: { $0.name == modelName }) else { return nil }
        return try? CoreMLTextEmbeddingGenerator(
            modelName: model.name,
            modelURL: model.modelURL,
            vocabURL: model.vocabURL
        )
    }

    private struct DiscoveredModel {
        let name: String
        let modelURL: URL
        let vocabURL: URL
    }

    private static func discoverModels() -> [DiscoveredModel] {
        guard let resourcesURL = Bundle.main.resourceURL else { return [] }
        let modelsDir = resourcesURL.appendingPathComponent("EmbeddingModels")
        guard FileManager.default.fileExists(atPath: modelsDir.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else { return [] }

        let modelDirs = contents.filter { $0.hasSuffix(".mlmodelc") }
        return modelDirs.compactMap { dir in
            let name = String(dir.dropLast(".mlmodelc".count))
            let modelURL = modelsDir.appendingPathComponent(dir)
            let vocabURL = modelsDir.appendingPathComponent("\(name).vocab.txt")
            guard FileManager.default.fileExists(atPath: vocabURL.path) else { return nil }
            return DiscoveredModel(name: name, modelURL: modelURL, vocabURL: vocabURL)
        }.sorted { a, b in
            // Single supported embedding model — the app bundles exactly one
            // (bge-small-en-v1.5); keep discovery order deterministic.
            let order = ["bge-small-en-v1.5"]
            let ai = order.firstIndex(of: a.name) ?? Int.max
            let bi = order.firstIndex(of: b.name) ?? Int.max
            return ai < bi
        }
    }

    private static func modelSizeMB(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int64 else { continue }
            total += size
        }
        return Int(total / 1_048_576)
    }
}
