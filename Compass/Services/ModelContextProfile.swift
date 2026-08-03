import Foundation

/// How the conversation context is bounded for the LLM request.
///
/// - `compaction`: Summarise older turns via a `.checkpoint` node; the request
///   projection drops everything before the latest checkpoint. Legacy strategy,
///   gated behind `COMPASS_CONTEXT_COMPACTION_ENABLED` and OFF by default — it has
///   been observed to drop the user's task goal and induce read-only loops.
/// - `slidingWindow`: Roll the committed chain to fit the model's context window
///   (token-budget-aware, front-truncated), preserving the most recent turns and
///   the original task as a goal anchor. No content is rewritten. The default.
/// - `passthrough`: Send the full immutable chain; let the provider handle
///   overflow. Best for very large-window models.
public enum ContextStrategy: String, Sendable, Codable {
    case compaction
    case slidingWindow
    case passthrough
}

/// Capabilities and recommended strategy for a given model or model family.
/// Used to decide at runtime whether to compact or let the full window through.
public struct ModelContextProfile: Sendable {
    public let modelID: String
    public let windowSize: Int
    public let supportsPrefixCache: Bool

    /// The strategy that best suits this model. The app uses this as the
    /// default but the user/coordinator may override via `ChatHistoryCoordinator.setStrategy(_:)`.
    public let defaultStrategy: ContextStrategy

    public init(
        modelID: String,
        windowSize: Int,
        supportsPrefixCache: Bool,
        defaultStrategy: ContextStrategy
    ) {
        self.modelID = modelID
        self.windowSize = windowSize
        self.supportsPrefixCache = supportsPrefixCache
        self.defaultStrategy = defaultStrategy
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
            .init(modelID: "anthropic/claude-sonnet-4", windowSize: 200_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "anthropic/claude-haiku-3":
            .init(modelID: "anthropic/claude-haiku-3", windowSize: 200_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "openai/gpt-4o":
            .init(modelID: "openai/gpt-4o", windowSize: 128_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "openai/gpt-5":
            .init(modelID: "openai/gpt-5", windowSize: 128_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "deepseek/deepseek":
            .init(modelID: "deepseek/deepseek", windowSize: 64_000, supportsPrefixCache: true, defaultStrategy: .compaction),
        "qwen":
            .init(modelID: "qwen", windowSize: 262_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "qwopus":
            .init(modelID: "qwopus", windowSize: 64_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "llama":
            .init(modelID: "llama", windowSize: 128_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "mistral":
            .init(modelID: "mistral", windowSize: 128_000, supportsPrefixCache: true, defaultStrategy: .slidingWindow),
        "gemma":
            .init(modelID: "gemma", windowSize: 32_000, supportsPrefixCache: true, defaultStrategy: .compaction),
    ]

    /// Safe fallback when no specific profile is registered.
    public static let `default` = ModelContextProfile(
        modelID: "unknown",
        windowSize: 32_000,
        supportsPrefixCache: false,
        defaultStrategy: .compaction
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
