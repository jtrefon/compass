import Foundation

/// Unified memory-pressure policy for local MLX inference (Fix 4).
///
/// **SRP/DRY:** the eviction decision previously lived in three places
/// (comments in `LocalModelProcessAIService`, the pre-gen FIM gate in
/// `NativeMLXGenerator`, and the RSS guard in `EngineMemoryMonitor`). One
/// policy, one home — both the pre-generation gate and the OS-pressure
/// handler consult this type.
///
/// **Tiered response:**
/// - `.warning` → evict FIM only (fast to reload; chat + its KV retained).
/// - `.critical` → evict FIM + release the MLX buffer cache (GPU scratch).
/// - `.critical` + compressor saturated → ALSO drop the conversation KV cache
///   (last resort). The next turn pays a full prefill, but the system stops
///   compressor-thrashing — the "death spiral" measured in telemetry (decode
///   halving 16.6→10 t/s as `vmCompressorPages` sat at 170–260K).
enum MemoryPressurePolicy {
    /// Compressor pages above which `.critical` also drops the conversation KV.
    /// ~100MB of compressed pages (256K pages × 4KB) = the OS is thrashing.
    static let compressorSaturationThresholdPages = 200_000

    /// Decides what to release for a given pressure level + vm state.
    /// Returns the set of release actions to perform.
    static func actions(
        for level: MemoryPressureLevel,
        compressorPages: Int?
    ) -> Set<PressureAction> {
        switch level {
        case .warning:
            return [.evictFIM]
        case .critical:
            var result: Set<PressureAction> = [.evictFIM, .releaseBufferCache]
            if let compressorPages, compressorPages > compressorSaturationThresholdPages {
                result.insert(.releaseConversationKV)
            }
            return result
        }
    }
}

enum PressureAction: Sendable, Hashable {
    case evictFIM
    case releaseBufferCache
    case releaseConversationKV
}
