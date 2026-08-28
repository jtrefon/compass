import Foundation

/// Process-wide registry of MLX-backed services that must release their
/// model containers under memory pressure. Chat generator, FIM, and any
/// future inference service register a labeled unload hook here; the
/// pressure handler unloads selectively (FIM only on warning) or everything
/// (critical) in one pass.
///
/// **Design rationale:**
/// - Converted from `class + NSLock + @unchecked Sendable` to an `actor`.
///   The handler array is mutable shared state; actor isolation serializes
///   access without manual lock discipline.
actor InferenceUnloadRegistry {
    static let shared = InferenceUnloadRegistry()

    static let chatLabel = "chat"
    static let fimLabel = "fim"

    private struct Handler {
        let label: String
        let body: @Sendable () async -> Void
    }

    private var handlers: [Handler] = []

    func register(label: String, _ handler: @escaping @Sendable () async -> Void) {
        handlers.append(Handler(label: label, body: handler))
    }

    /// Unloads all handlers, or only those matching `labels` when provided.
    func removeAllHandlers() {
        handlers.removeAll()
    }

    func unloadAll(labels: Set<String>? = nil) async {
        let snapshot = handlers
        for handler in snapshot where labels == nil || labels?.contains(handler.label) == true {
            await handler.body()
        }
    }
}
