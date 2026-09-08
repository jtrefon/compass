import Foundation

/// Serializes MLX inference across engines (chat generator + FIM). Both use
/// the shared MLX allocator — concurrent GPU streams thrash the pool and the
/// chat RSS guard counts FIM weights, killing chat generation mid-stream. One
/// inference at a time.
///
/// **FIFO fairness:** waiters acquire in arrival order (no starvation), unlike
/// the previous spin-poll which had no queue ordering.
///
/// **Bounded wait:** a waiter that exceeds `timeout` logs a telemetry event
/// and returns a timeout error instead of blocking forever. A legitimate long
/// generation can hold the lock for its full duration — the problem this
/// solves is *silent unbounded waiting* with no visibility (measured: a
/// 24.5s lock wait in live telemetry).
actor MLXInferenceLock {
    static let shared = MLXInferenceLock()

    /// Default max wait before a waiter times out (overridable via
    /// `COMPASS_MLX_LOCK_TIMEOUT_MS`).
    static let defaultTimeoutMs: UInt64 = 30_000

    private var active = false
    private var waiters = 0

    /// Acquire the inference lock, waiting FIFO up to `timeoutMs`.
    ///
    /// Cancellation-aware: if the caller is cancelled while waiting, throws
    /// `CancellationError` instead of wart-holding a slot and then loading the
    /// full model + prefill for a generation nobody wants.
    func acquire(timeoutMs: UInt64 = defaultTimeoutMs) async throws {
        waiters += 1
        let queueDepth = waiters
        let start = ContinuousClock.now
        while active {
            try Task.checkCancellation()
            let elapsedMs = UInt64(Double(start.duration(to: .now).components.seconds) * 1000)
            if elapsedMs >= timeoutMs {
                waiters -= 1
                await logTimeout(elapsedMs: elapsedMs, queueDepth: queueDepth)
                throw MLXInferenceLockError.timeout(elapsedMs: elapsedMs)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        waiters -= 1
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

    private func logTimeout(elapsedMs: UInt64, queueDepth: Int) async {
        await AIToolTraceLogger.shared.log(type: "mlx.lock_timeout", data: [
            "waitMs": elapsedMs,
            "queueDepth": queueDepth
        ])
    }
}

enum MLXInferenceLockError: Error, Equatable {
    case timeout(elapsedMs: UInt64)
}
