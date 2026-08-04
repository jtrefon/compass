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
    let endOfText: String

    static let qwen25Coder = FIMTokens(
        prefix: "<|fim_prefix|>",
        suffix: "<|fim_suffix|>",
        middle: "<|fim_middle|>",
        endOfText: "<|endoftext|>"
    )
}

struct LocalModelDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let artifacts: [LocalModelArtifact]
    let defaultContextLength: Int
    let supportsQuantizedKVCache: Bool

    init(id: String, displayName: String, artifacts: [LocalModelArtifact], defaultContextLength: Int = 4096, supportsQuantizedKVCache: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.artifacts = artifacts
        self.defaultContextLength = defaultContextLength
        self.supportsQuantizedKVCache = supportsQuantizedKVCache
    }
}
