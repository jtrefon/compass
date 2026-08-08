import Foundation

/// Process-wide registry of MLX-backed services that must release their
/// model containers under memory pressure. Chat generator, FIM, and any
/// future inference service register a labeled unload hook here; the
/// pressure handler unloads selectively (FIM only on warning) or everything
/// (critical) in one pass.
final class InferenceUnloadRegistry: @unchecked Sendable {
    static let shared = InferenceUnloadRegistry()

    static let chatLabel = "chat"
    static let fimLabel = "fim"

    private struct Handler {
        let label: String
        let body: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var handlers: [Handler] = []

    func register(label: String, _ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        handlers.append(Handler(label: label, body: handler))
        lock.unlock()
    }

    /// Unloads all handlers, or only those matching `labels` when provided.
    /// Test hygiene: clears all registered handlers.
    func removeAllHandlers() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    func unloadAll(labels: Set<String>? = nil) async {
        let snapshot = snapshotHandlers()
        for handler in snapshot where labels == nil || labels?.contains(handler.label) == true {
            await handler.body()
        }
    }

    private func snapshotHandlers() -> [Handler] {
        lock.lock()
        defer { lock.unlock() }
        return handlers
    }
}
