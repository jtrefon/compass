import Foundation
import CryptoKit
import MLX
@preconcurrency import MLXLMCommon

/// Owns the conversation-KV cache: the in-memory LRU of resident
/// `[KVCache]` arrays per conversation, and the disk persistence
/// (system-prefix cache + conversation cache).
///
/// **SRP:** extraction from `NativeMLXGenerator` (was a 1140-line god-object).
/// The generator owns generation; this owns cache. One cache policy, one home.
///
/// **Key design (from a fixed regression):** the cache key must NOT include
/// the context window / maxKVSize — a slider change mid-session orphaned the
/// resident KV (new key → empty entry → full re-prefill). KV content is
/// config-independent: only quantization (q4) and the system-prefix hash shape
/// reuse. Capacity is enforced at reuse time by the `offset > maxSize` guard.
actor ConversationKVCache {
    /// Only the ACTIVE session's KV is resident (16GB M4: a second
    /// conversation's KV — 4-bit ~750MB at 24k, FP16 ~3GB — competes with the
    /// active one for unified memory). A format flip (q4↔fp16) re-keys the
    /// entry, so the old-format cache is evicted on the next resolve instead
    /// of lingering in RAM.
    private static let maxPromptCacheConversations = 1
    private static let maxPrefixCacheFiles = 2
    /// Conversation disk caches kept (most recent N), bounded disk usage.
    private static let maxConversationCacheFiles = 3

    private var promptCacheByConversation: [String: PromptCacheEntry] = [:]
    private var promptCacheAccessOrder: [String] = []
    private var savedPrefixCacheHashes: Set<String> = []
    /// The most recently resolved entry (the active conversation). Used to
    /// persist the resident KV to disk on unload/session end.
    private var activeKey: String?
    private var activeConversationId: String?
    private var activeModelDirectory: URL?
    private var activePrefixCache: PrefixCacheContext?

    // MARK: - In-memory LRU

    private func promptCacheKey(conversationId: String, modelDirectory: URL) -> String {
        "\(conversationId):\(modelDirectory.standardizedFileURL.path)"
    }

    private func cachePolicy(prefixHash: String?, kvCache4Bit: Bool) -> String {
        "q4=\(kvCache4Bit):prefix=\(prefixHash ?? "none")"
    }

    /// Resolves (or creates) the cache entry for a conversation, seeding from
    /// the disk prefix cache when available. Evicts the LRU entry when at cap.
    func resolveEntry(
        conversationId: String?,
        modelDirectory: URL,
        prefixCache: PrefixCacheContext?,
        kvCache4Bit: Bool
    ) -> PromptCacheEntry? {
        guard let conversationId else { return nil }
        let key = "\(promptCacheKey(conversationId: conversationId, modelDirectory: modelDirectory)):\(cachePolicy(prefixHash: prefixCache?.hash, kvCache4Bit: kvCache4Bit))"
        // Track the active conversation for on-unload disk persistence.
        activeKey = key
        activeConversationId = conversationId
        activeModelDirectory = modelDirectory
        activePrefixCache = prefixCache
        if let existing = promptCacheByConversation[key] {
            // touch for LRU
            promptCacheAccessOrder.removeAll { $0 == key }
            promptCacheAccessOrder.append(key)
            return existing
        }
        if promptCacheByConversation.count >= Self.maxPromptCacheConversations,
           let evictKey = promptCacheAccessOrder.first {
            promptCacheAccessOrder.removeFirst()
            if let evicted = promptCacheByConversation.removeValue(forKey: evictKey) {
                evicted.clear()
            }
        }
        let entry = PromptCacheEntry()
        promptCacheByConversation[key] = entry
        promptCacheAccessOrder.append(key)
        // Seed new conversations from the disk-persisted system-prefix cache.
        if let prefixCache, FileManager.default.fileExists(atPath: prefixCache.url.path) {
            let diskStart = ContinuousClock.now
            if let loaded = Self.loadPrefixCache(prefixCache) {
                let diskMs = Self.milliseconds(diskStart.duration(to: ContinuousClock.now))
                let bytes = (try? FileManager.default.attributesOfItem(atPath: prefixCache.url.path)[.size] as? Int) ?? 0
                Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "load_prefix", "hit": true, "durationMs": diskMs, "sizeBytes": bytes, "hash": prefixCache.hash]) }
                entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds, promptCount: loaded.tokenIds.count)
                entry.systemHash = prefixCache.hash
            } else {
                let diskMs = Self.milliseconds(diskStart.duration(to: ContinuousClock.now))
                Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "load_prefix", "hit": false, "durationMs": diskMs, "hash": prefixCache.hash]) }
            }
        }
        // Seed from the conversation disk cache (Fix 3): a session break with
        // the same conversationId + system hash restores the full history KV.
        if let prefixCache {
            let convURL = Self.conversationCacheURL(
                directory: prefixCache.url.deletingLastPathComponent(),
                conversationId: conversationId,
                modelDirectory: modelDirectory,
                systemHash: prefixCache.hash
            )
            if FileManager.default.fileExists(atPath: convURL.path) {
                let diskStart = ContinuousClock.now
                if let loaded = Self.loadConversationCache(url: convURL, systemHash: prefixCache.hash) {
                    let diskMs = Self.milliseconds(diskStart.duration(to: ContinuousClock.now))
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: convURL.path)[.size] as? Int) ?? 0
                    Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "load_conv", "hit": true, "durationMs": diskMs, "sizeBytes": bytes, "conversationId": conversationId]) }
                    entry.set(cache: loaded.cache, tokenIds: loaded.tokenIds, promptCount: loaded.tokenIds.count)
                    entry.systemHash = prefixCache.hash
                } else {
                    let diskMs = Self.milliseconds(diskStart.duration(to: ContinuousClock.now))
                    Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "load_conv", "hit": false, "durationMs": diskMs, "conversationId": conversationId]) }
                }
            }
        }
        return entry
    }

    /// Persists the ACTIVE conversation's KV to disk (Fix 3) so a session break
    /// resumes with a disk-load + delta instead of a full history re-prefill.
    /// Called on unload/session end. Best-effort; bounded by
    /// `maxConversationCacheFiles`.
    func persistActiveConversationIfPossible() async {
        guard let activeConversationId,
              let entry = promptCacheByConversation[activeKey ?? ""],
              let cache = entry.cache, !cache.isEmpty,
              !entry.promptTokenIds.isEmpty,
              let prefixCache = activePrefixCache,
              let modelDirectory = activeModelDirectory else { return }
        let url = Self.conversationCacheURL(
            directory: prefixCache.url.deletingLastPathComponent(),
            conversationId: activeConversationId,
            modelDirectory: modelDirectory,
            systemHash: prefixCache.hash
        )
        do {
            try savePromptCache(
                url: url,
                cache: cache,
                metadata: [
                    "systemHash": prefixCache.hash,
                    "tokenIds": entry.promptTokenIds.map(String.init).joined(separator: ","),
                ]
            )
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "save_conv", "hit": true, "sizeBytes": bytes]) }
            Self.evictConversationCacheFiles(directory: prefixCache.url.deletingLastPathComponent(), keep: Self.maxConversationCacheFiles)
        } catch {
            Task { await AIToolTraceLogger.shared.log(type: "mlx.kv_disk", data: ["op": "save_conv", "hit": false, "error": String(describing: error)]) }
        }
    }

    func clearAll() {
        for entry in promptCacheByConversation.values {
            entry.clear()
        }
        promptCacheByConversation.removeAll()
        promptCacheAccessOrder.removeAll()
        activeKey = nil
        activeConversationId = nil
        activeModelDirectory = nil
        activePrefixCache = nil
    }

    func markPrefixCacheSaved(_ hash: String) {
        savedPrefixCacheHashes.insert(hash)
    }

    func hasPrefixCache(_ hash: String) -> Bool {
        savedPrefixCacheHashes.contains(hash)
    }

    // MARK: - Disk helpers

    nonisolated private static func conversationCacheURL(
        directory: URL,
        conversationId: String,
        modelDirectory: URL,
        systemHash: String
    ) -> URL {
        let digest = String(SHA256.hash(data: Data("\(conversationId):\(modelDirectory.standardizedFileURL.path):\(systemHash)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        return directory.appendingPathComponent("kv-conv-\(digest).safetensors")
    }

    /// Loads the disk prefix cache, validating the hash metadata. Returns nil
    /// (and deletes the stale file) on any mismatch — the caller falls back to
    /// a fresh prefill, which is always safe.
    nonisolated static func loadPrefixCache(_ prefixCache: PrefixCacheContext) -> (cache: [KVCache], tokenIds: [Int])? {
        guard let (caches, metadata) = try? loadPromptCache(url: prefixCache.url),
              metadata["systemHash"] == prefixCache.hash,
              let tokenIdsRaw = metadata["tokenIds"] else {
            try? FileManager.default.removeItem(at: prefixCache.url)
            return nil
        }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else {
            try? FileManager.default.removeItem(at: prefixCache.url)
            return nil
        }
        return (caches, tokenIds)
    }

    /// Loads a conversation disk cache, validating the system-hash metadata.
    nonisolated private static func loadConversationCache(
        url: URL,
        systemHash: String
    ) -> (cache: [KVCache], tokenIds: [Int])? {
        guard let (caches, metadata) = try? loadPromptCache(url: url),
              metadata["systemHash"] == systemHash,
              let tokenIdsRaw = metadata["tokenIds"] else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let tokenIds = tokenIdsRaw.split(separator: ",").compactMap { Int($0) }
        guard !tokenIds.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (caches, tokenIds)
    }

    nonisolated private static func evictConversationCacheFiles(directory: URL, keep: Int) {
        guard let allFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let convFiles = allFiles.filter {
            $0.pathExtension == "safetensors" && $0.lastPathComponent.hasPrefix("kv-conv-")
        }
        let sorted = convFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for file in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000) + (Double(duration.components.attoseconds) / 1_000_000_000_000_000))
    }
}
