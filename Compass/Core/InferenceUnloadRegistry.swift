import Foundation

/// Process-wide registry of MLX-backed services that must release their
/// model containers under memory pressure. Chat generator, FIM, and any
/// future inference service register an unload hook here; the pressure
/// handler unloads everything in one pass.
final class InferenceUnloadRegistry: @unchecked Sendable {
    static let shared = InferenceUnloadRegistry()

    private let lock = NSLock()
    private var handlers: [@Sendable () async -> Void] = []

    func register(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func unloadAll() async {
        let snapshot = snapshotHandlers()
        for handler in snapshot {
            await handler()
        }
    }

    private func snapshotHandlers() -> [@Sendable () async -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return handlers
    }
}
