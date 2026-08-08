import Foundation
@preconcurrency import MLXLMCommon

struct LocalModelArtifact: Hashable, Sendable {
    let fileName: String
    let url: URL
}

/// FIM (fill-in-the-middle) tokens for the fixed FIM model (Qwen2.5-Coder-1.5B).
struct FIMTokens: Sendable {
    let prefix: String
    let suffix: String
    let middle: String

    static let qwen25Coder = FIMTokens(
        prefix: "<|fim_prefix|>",
        suffix: "<|fim_suffix|>",
        middle: "<|fim_middle|>"
    )
}

struct LocalModelDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let artifacts: [LocalModelArtifact]
    let defaultContextLength: Int
    /// Hard ceiling for the model's context window (config.json
    /// max_position_embeddings). The settings slider extends up to here; the
    /// inference layer honors it as the resolved context cap.
    let maxContextLength: Int
    let supportsQuantizedKVCache: Bool

    init(id: String, displayName: String, artifacts: [LocalModelArtifact], defaultContextLength: Int = 4096, maxContextLength: Int = 262_144, supportsQuantizedKVCache: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.artifacts = artifacts
        self.defaultContextLength = defaultContextLength
        self.maxContextLength = maxContextLength
        self.supportsQuantizedKVCache = supportsQuantizedKVCache
    }
}
