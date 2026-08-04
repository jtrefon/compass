import Foundation

/// Capabilities and recommended profile for a given model or model family.
/// Used to decide at runtime how the context window is handled.
public struct ModelContextProfile: Sendable {
    public let modelID: String
    public let windowSize: Int
    public let supportsPrefixCache: Bool

    public init(
        modelID: String,
        windowSize: Int,
        supportsPrefixCache: Bool
    ) {
        self.modelID = modelID
        self.windowSize = windowSize
        self.supportsPrefixCache = supportsPrefixCache
    }
}

// MARK: — Registry

extension ModelContextProfile {
    /// Known model profiles. Keys are prefix-matched against the provider's
    /// model string (e.g. `"anthropic/claude-sonnet-4-2025-01-01"` matches
    /// `"anthropic/claude-sonnet-4"`).
    ///
    /// Models with large context windows **and** prefix-cache support default to
    /// `slidingWindow` — keep the full chain and let the cache handle the prefix.
    /// Everything else defaults to `compaction`.
    public static let registry: [String: ModelContextProfile] = [
        "anthropic/claude-sonnet-4":
            .init(modelID: "anthropic/claude-sonnet-4", windowSize: 200_000, supportsPrefixCache: true),
        "anthropic/claude-haiku-3":
            .init(modelID: "anthropic/claude-haiku-3", windowSize: 200_000, supportsPrefixCache: true),
        "openai/gpt-4o":
            .init(modelID: "openai/gpt-4o", windowSize: 128_000, supportsPrefixCache: true),
        "openai/gpt-5":
            .init(modelID: "openai/gpt-5", windowSize: 128_000, supportsPrefixCache: true),
        "deepseek/deepseek":
            .init(modelID: "deepseek/deepseek", windowSize: 64_000, supportsPrefixCache: true),
        "qwen":
            .init(modelID: "qwen", windowSize: 262_000, supportsPrefixCache: true),
        "qwopus":
            .init(modelID: "qwopus", windowSize: 64_000, supportsPrefixCache: true),
        "llama":
            .init(modelID: "llama", windowSize: 128_000, supportsPrefixCache: true),
        "mistral":
            .init(modelID: "mistral", windowSize: 128_000, supportsPrefixCache: true),
        "gemma":
            .init(modelID: "gemma", windowSize: 32_000, supportsPrefixCache: true),
    ]

    /// Safe fallback when no specific profile is registered.
    public static let `default` = ModelContextProfile(
        modelID: "unknown",
        windowSize: 32_000,
        supportsPrefixCache: false
    )

    /// Lookup a profile by prefix-matching against the registry keys.
    /// Returns the default profile when no key matches.
    public static func profile(for modelID: String) -> ModelContextProfile {
        let lower = modelID.lowercased()
        for (key, profile) in registry where lower.hasPrefix(key) {
            return profile
        }
        return `default`
    }
}
