import Foundation

/// Serializes MLX inference across engines (chat generator + FIM). Both use
/// the shared MLX allocator (128MB cache / 3GB pool set in NativeMLXGenerator)
/// — concurrent GPU streams thrash the pool and the chat RSS guard counts FIM
/// weights, killing chat generation mid-stream. One inference at a time.
actor MLXInferenceLock {
    static let shared = MLXInferenceLock()

    private var active = false
    private var waiters = 0

    /// Acquire the inference lock.
    ///
    /// Cancellation-aware: if the caller is cancelled while waiting, throws
    /// `CancellationError` instead of wart-holding a slot and then loading the
    /// full model + prefill for a generation nobody wants. Polls briefly while
    /// waiting so a cancelled waiter never wedges the queue.
    func acquire() async throws {
        waiters += 1
        defer { waiters -= 1 }
        while active {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        active = true
    }

    /// Non-blocking acquire for best-effort background work (KV prefix-cache
    /// persistence). Returns false if the GPU is busy OR another task is queued
    /// ahead — the caller must skip its work in that case, never wait for it.
    func tryAcquire() -> Bool {
        guard !active, waiters == 0 else { return false }
        active = true
        return true
    }

    func release() {
        active = false
    }
}