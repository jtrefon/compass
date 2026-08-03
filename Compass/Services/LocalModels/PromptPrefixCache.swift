import Foundation
import CryptoKit

/// Caches prompt prefixes (system prompts + tool definitions) to avoid rebuilding on each turn.
///
/// While MLX handles tokenization internally, caching the prefix string provides:
/// - Consistent prompt structure across turns
/// - Tracking of prefix characteristics for optimization
/// - Foundation for future KV cache integration
actor PromptPrefixCache {
    /// A cached prefix entry
    struct CachedPrefix: Sendable {
        /// The conversation ID this prefix belongs to
        let conversationId: String
        
        /// The model ID this prefix was built for
        let modelId: String
        
        /// The complete system prompt string
        let systemPrompt: String
        
        /// Hash of the tools configuration
        let toolsHash: String
        
        /// The mode used when building this prefix
        let mode: String
        
        /// Approximate token count (estimated from word count)
        let estimatedTokenCount: Int
        
        /// When this cache entry was created
        let timestamp: Date
        
        /// Number of times this prefix has been reused
        var reuseCount: Int
    }
    
    /// Statistics about cache performance
    struct CacheStatistics: Sendable {
        var totalRequests: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
        var totalTokensSaved: Int = 0
        
        var hitRate: Double {
            guard totalRequests > 0 else { return 0 }
            return Double(cacheHits) / Double(totalRequests)
        }
    }
    
    // MARK: - Private State
    
    private var cachedPrefixes: [String: CachedPrefix] = [:]
    private var statistics = CacheStatistics()
    
    /// Maximum number of conversations to cache prefixes for
    private let maxCachedConversations: Int
    
    /// LRU tracking for eviction
    private var accessOrder: [String] = []
    
    // MARK: - Initialization
    
    init(maxCachedConversations: Int = 10) {
        self.maxCachedConversations = maxCachedConversations
    }
    
    // MARK: - Public API
    
    /// Get a cached prefix if it matches the current configuration
    /// - Returns: The cached prefix if valid, nil otherwise
    func getCachedPrefix(
        conversationId: String,
        modelId: String,
        systemPrompt: String,
        tools: [AITool]?,
        mode: AIMode?
    ) -> CachedPrefix? {
        statistics.totalRequests += 1
        
        let key = cacheKey(conversationId: conversationId, modelId: modelId)
        let toolsHash = hashTools(tools)
        let modeString = mode?.rawValue ?? "none"
        
        guard let cached = cachedPrefixes[key] else {
            statistics.cacheMisses += 1
            return nil
        }
        
        // Validate that the cached prefix still matches
        guard cached.systemPrompt == systemPrompt &&
              cached.toolsHash == toolsHash &&
              cached.mode == modeString else {
            // Configuration mismatch - treat as miss but keep prior entry intact.
            // This allows subsequent requests that match the original configuration
            // to continue benefiting from the cached prefix.
            statistics.cacheMisses += 1
            return nil
        }
        
        // Cache hit - update LRU and statistics
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        
        statistics.cacheHits += 1
        statistics.totalTokensSaved += cached.estimatedTokenCount
        
        // Update reuse count
        var updatedCached = cached
        updatedCached.reuseCount += 1
        cachedPrefixes[key] = updatedCached
        
        return cached
    }
    
    /// Store a prefix in the cache
    func storePrefix(
        conversationId: String,
        modelId: String,
        systemPrompt: String,
        tools: [AITool]?,
        mode: AIMode?
    ) {
        let key = cacheKey(conversationId: conversationId, modelId: modelId)
        let toolsHash = hashTools(tools)
        let modeString = mode?.rawValue ?? "none"
        let estimatedTokens = estimateTokenCount(systemPrompt)
        
        // Evict oldest if at capacity
        if cachedPrefixes.count >= maxCachedConversations, let oldest = accessOrder.first {
            cachedPrefixes.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        
        cachedPrefixes[key] = CachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            toolsHash: toolsHash,
            mode: modeString,
            estimatedTokenCount: estimatedTokens,
            timestamp: Date(),
            reuseCount: 0
        )
        
        accessOrder.append(key)
    }
    
    /// Invalidate cache for a specific conversation
    func invalidateCache(conversationId: String) {
        let keysToRemove = cachedPrefixes.keys.filter { key in
            key.hasPrefix(conversationId)
        }
        
        for key in keysToRemove {
            cachedPrefixes.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
    }
    
    /// Clear all cached prefixes
    func clearAll() {
        cachedPrefixes.removeAll()
        accessOrder.removeAll()
    }
    
    /// Get current cache statistics
    func getStatistics() -> CacheStatistics {
        statistics
    }
    
    /// Reset statistics (useful for testing)
    func resetStatistics() {
        statistics = CacheStatistics()
    }
    
    // MARK: - Private Helpers
    
    private func cacheKey(conversationId: String, modelId: String) -> String {
        "\(conversationId)_\(modelId)"
    }
    
    /// Create a stable hash for tools configuration
    private func hashTools(_ tools: [AITool]?) -> String {
        guard let tools, !tools.isEmpty else { return "no_tools" }
        
        // Sort tools by name for consistent hashing
        let sortedNames = tools.map { $0.name }.sorted()
        let combined = sortedNames.joined(separator: "|")
        
        return hashString(combined)
    }
    
    /// Hash a string using SHA256 (truncated for readability)
    private func hashString(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }
    
    /// Estimate token count from string
    /// Uses a simple heuristic: ~4 characters per token for English text
    private func estimateTokenCount(_ text: String) -> Int {
        // More accurate estimation considering:
        // - Whitespace-separated words
        // - Code typically has more tokens per character
        // - Punctuation adds tokens
        
        let wordCount = text.split(separator: " ").count
        let punctuationCount = text.filter { ",.!?;:()[]{}\"'".contains($0) }.count
        let newlineCount = text.filter { $0 == "\n" }.count
        
        // Rough estimation: words + punctuation + newlines
        // Adjusted for typical code assistant prompts
        return wordCount + (punctuationCount / 2) + newlineCount
    }
}

// MARK: - AITool Extension for Hashing

extension AITool {
    /// A stable string representation for hashing
    var stableRepresentation: String {
        "\(name)_\(description)"
    }
}
