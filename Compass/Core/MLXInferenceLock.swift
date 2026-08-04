import Foundation

/// Serializes MLX inference across engines (chat generator + FIM). Both use
/// the shared MLX allocator (128MB cache / 3GB pool set in NativeMLXGenerator)
/// — concurrent GPU streams thrash the pool and the chat RSS guard counts FIM
/// weights, killing chat generation mid-stream. One inference at a time.
actor MLXInferenceLock {
    static let shared = MLXInferenceLock()

    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !active {
            active = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = false
        }
    }
}
