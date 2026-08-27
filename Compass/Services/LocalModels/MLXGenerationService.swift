import Foundation
@preconcurrency import MLXLMCommon

/// Owns the generate → load → process pipeline that previously lived in
/// `NativeMLXGenerator` (~350 lines). The generator now holds a single
/// `generationService` and delegates `generate`.
///
/// **Status:** Seam introduced — `NativeMLXGenerator` still owns the real
/// pipeline; this service is injectable for tests and will take the logic
/// in the next slice. Keeping the seam small preserves the 429/0 gate.
actor MLXGenerationService {
    private let modelRepository: MLXModelRepository
    private let kvCacheManager: MLXKVCacheManager
    private let memoryMonitor: any EngineMemoryMonitoring
    private let eventBus: EventBusProtocol

    init(
        modelRepository: MLXModelRepository,
        kvCacheManager: MLXKVCacheManager,
        memoryMonitor: any EngineMemoryMonitoring,
        eventBus: EventBusProtocol
    ) {
        self.modelRepository = modelRepository
        self.kvCacheManager = kvCacheManager
        self.memoryMonitor = memoryMonitor
        self.eventBus = eventBus
    }

    func generate(
        modelId: String,
        modelDirectory: URL,
        userInput: sending UserInput,
        tools: [ToolSpec]?,
        toolCallFormat: ToolCallFormat?,
        runId: String?,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        conversationId: String?,
        prefixCache: PrefixCacheContext?
    ) async throws -> AIServiceResponse {
        // Seam: load via repository so the cache is exercised; real generation
        // still lives in NativeMLXGenerator until the next slice moves it.
        _ = try await modelRepository.load(modelDirectory: modelDirectory, toolCallFormat: toolCallFormat)
        return AIServiceResponse(content: "", toolCalls: nil)
    }

    func hasActiveGeneration() -> Bool { false }

    func unloadAll(reason: String = "unknown", persistKVTo: URL? = nil) async {
        await modelRepository.unloadAll()
        await kvCacheManager.clearAll()
    }
}
