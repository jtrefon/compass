import Foundation
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

/// Owns the MLX model-container cache and in-flight deduplication that
/// previously lived in `NativeMLXGenerator` (1001 lines). The generator now
/// holds a single `modelRepository` and delegates `load`/`unload`.
///
/// **Design rationale:**
/// - Bounded LRU (max 1) + in-flight `Task` dedup is a self-contained
///   repository concern, orthogonal to generation/KV/memory.
/// - `actor` isolation serializes cache access without `NSLock`.
actor MLXModelRepository {
    private var containersByModelDirectory: [URL: ModelContainer] = [:]
    private var inFlightLoads: [URL: Task<ModelContainer, Error>] = [:]
    private var accessOrder: [URL] = []
    private let maxCachedModels = 1

    /// Loads a container, reusing a cached entry or coalescing concurrent
    /// callers onto a single in-flight `Task`.
    func load(modelDirectory: URL, toolCallFormat: ToolCallFormat? = nil) async throws -> ModelContainer {
        let cacheKey = modelDirectory.resolvingSymlinksInPath().standardizedFileURL

        if let existing = containersByModelDirectory[cacheKey] {
            accessOrder.removeAll { $0 == cacheKey }
            accessOrder.append(cacheKey)
            return existing
        }

        if let existingTask = inFlightLoads[cacheKey] {
            return try await existingTask.value
        }

        if containersByModelDirectory.count >= maxCachedModels, let oldest = accessOrder.first {
            containersByModelDirectory.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        let loadTask = Task<ModelContainer, Error> {
            try await self.loadModelContainer(modelDirectory: cacheKey, toolCallFormat: toolCallFormat)
        }
        inFlightLoads[cacheKey] = loadTask

        let container: ModelContainer
        do {
            container = try await loadTask.value
        } catch {
            inFlightLoads.removeValue(forKey: cacheKey)
            throw error
        }

        inFlightLoads.removeValue(forKey: cacheKey)
        containersByModelDirectory[cacheKey] = container
        accessOrder.append(cacheKey)
        return container
    }

    func unloadAll() {
        containersByModelDirectory.removeAll()
        inFlightLoads.removeAll()
        accessOrder.removeAll()
    }

    func unload(modelDirectory: URL) {
        let cacheKey = modelDirectory.resolvingSymlinksInPath().standardizedFileURL
        containersByModelDirectory.removeValue(forKey: cacheKey)
        inFlightLoads.removeValue(forKey: cacheKey)
        accessOrder.removeAll { $0 == cacheKey }
    }

    var count: Int { containersByModelDirectory.count }

    // MARK: - Private

    private func loadModelContainer(modelDirectory: URL, toolCallFormat: ToolCallFormat?) async throws -> ModelContainer {
        let tokenizerLoader = LocalTokenizerLoader(directory: modelDirectory)
        return try await LLMModelFactory.shared.loadContainer(from: modelDirectory, using: tokenizerLoader)
    }
}
