import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon

/// Owns the conversation-KV cache and system-prefix disk cache that previously
/// lived in `NativeMLXGenerator` (1001 lines). The generator now holds a
/// single `kvCacheManager` and delegates `resolve`/`persist`/`evict`.
///
/// **Design rationale:**
/// - Bounded LRU (max 1 conversation) + system-prefix hash check is a
///   self-contained cache concern, orthogonal to model loading/generation.
/// - `actor` isolation serializes cache access without `NSLock` (replaces
///   `PromptCacheEntry.lock` + manual `accessOrder` races).
actor MLXKVCacheManager {
    private var promptCacheByConversation: [String: PromptCacheEntry] = [:]
    private var promptCacheAccessOrder: [String] = []
    private var savedPrefixCacheHashes: Set<String> = []
    private let maxPromptCacheConversations = 1

    private func promptCacheKey(conversationId: String, modelDirectory: URL) -> String {
        "\(conversationId):\(modelDirectory.standardizedFileURL.path)"
    }

    /// Resolves (or creates) the cache entry for `conversationId`/`modelDirectory`,
    /// seeding from disk prefix / conversation caches when available.
    func resolveEntry(
        conversationId: String?,
        modelDirectory: URL,
        prefixCache: PrefixCacheContext?,
        inferenceConfiguration: LocalModelInferenceConfiguration
    ) -> PromptCacheEntry? {
        guard let conversationId else { return nil }
        let cachePolicy = "ctx=\(inferenceConfiguration.contextLength):kv=\(inferenceConfiguration.maxKVSize):q4=\(inferenceConfiguration.kvCache4BitEnabled):prefix=\(prefixCache?.hash ?? "none")"
        let key = "\(promptCacheKey(conversationId: conversationId, modelDirectory: modelDirectory)):\(cachePolicy)"
        if let existing = promptCacheByConversation[key] {
            promptCacheAccessOrder.removeAll { $0 == key }
            promptCacheAccessOrder.append(key)
            return existing
        }
        if promptCacheByConversation.count >= maxPromptCacheConversations, let evictKey = promptCacheAccessOrder.first {
            promptCacheAccessOrder.removeFirst()
            promptCacheByConversation.removeValue(forKey: evictKey)
        }
        let entry = PromptCacheEntry()
        promptCacheByConversation[key] = entry
        promptCacheAccessOrder.append(key)
        if let prefixCache, FileManager.default.fileExists(atPath: prefixCache.url.path) {
            if let loaded = Self.loadPrefixCache(prefixCache) {
                entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds)
                entry.systemHash = prefixCache.hash
            }
        }
        if let prefixCache,
           let loaded = Self.loadConversationCache(
               directory: prefixCache.url.deletingLastPathComponent(),
               conversationKey: key,
               expectedHash: prefixCache.hash
           ) {
            entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds)
            entry.systemHash = prefixCache.hash
        }
        return entry
    }

    func clearAll() {
        promptCacheByConversation.removeAll()
        promptCacheAccessOrder.removeAll()
    }

    func clearAllConversations() {
        promptCacheByConversation.removeAll()
        promptCacheAccessOrder.removeAll()
    }

    func entryCount() -> Int { promptCacheByConversation.count }

    // MARK: - Disk prefix / conversation helpers (static, no actor state)

    nonisolated static func loadPrefixCache(_ prefixCache: PrefixCacheContext) -> (cache: [KVCache], tokenIds: [Int])? {
        guard FileManager.default.fileExists(atPath: prefixCache.url.path),
              let (caches, metadata) = try? loadPromptCache(url: prefixCache.url),
              metadata["systemHash"] == prefixCache.hash,
              let tokenIdsRaw = metadata["tokenIds"] else { return nil }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else { return nil }
        return (caches, tokenIds)
    }

    nonisolated static func loadConversationCache(
        directory: URL,
        conversationKey: String,
        expectedHash: String
    ) -> (cache: [KVCache], tokenIds: [Int])? {
        let digest = String(SHA256.hash(data: Data(conversationKey.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        let url = directory.appendingPathComponent("kv-conv-\(digest).safetensors")
        guard FileManager.default.fileExists(atPath: url.path),
              let (caches, metadata) = try? loadPromptCache(url: url),
              metadata["systemHash"] == expectedHash,
              let tokenIdsRaw = metadata["tokenIds"] else { return nil }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else { return nil }
        return (caches, tokenIds)
    }

    nonisolated static func evictPrefixCacheFiles(directory: URL, keep: Int = 8) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return }
        let prefixFiles = contents.filter { $0.lastPathComponent.hasPrefix("kv-") }.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard prefixFiles.count > keep else { return }
        for url in prefixFiles.prefix(prefixFiles.count - keep) {
            try? fm.removeItem(at: url)
        }
    }
}

private extension URL {
    var creationDate: Date? {
        (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
