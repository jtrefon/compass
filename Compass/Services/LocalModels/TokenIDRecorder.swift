import Foundation
import MLX
@preconcurrency import MLXLMCommon

/// Records every sampled token ID, so the KV-cache reuse bookkeeping can store
/// the EXACT token sequence written into the cache. Re-encoding the emitted
/// text is not round-trip stable and desynchronizes the common-prefix trim math
/// (the fix for the second-turn GatedDeltaNet shape/validity crashes).
///
/// Wraps the standard generation processor (repetition penalty) so the two
/// compose, mirroring `FIMBannedTokenProcessor`.
///
/// **Performance-critical design:** sampled tokens are stored as lazy
/// `MLXArray` references — NOT materialized via `.item()` during generation.
/// Calling `.item(Int.self)` per token forces a GPU→CPU synchronization that
/// destroys `asyncEval` pipelining (the GPU cannot start the next token until
/// the current one is copied to CPU). Instead, the arrays are collected
/// lazily and materialized in a single batch AFTER generation completes
/// (one GPU sync instead of N). Use ``tokenCount`` for live count access
/// during generation; use ``tokenIDs`` only after the generation loop ends.
final class TokenIDRecorder: LogitProcessor, @unchecked Sendable {
    private var upstream: (any LogitProcessor)?
    private let lock = NSLock()
    private var _pendingTokens: [MLXArray] = []
    private var _tokenCount: Int = 0

    init(upstream: (any LogitProcessor)?) {
        self.upstream = upstream
    }

    /// Materialized token IDs — calls `.item()` in batch. **Call only AFTER
    /// generation completes** — calling during generation forces a per-token
    /// GPU sync that breaks asyncEval pipelining. One-shot: empties the
    /// internal buffer on access.
    var tokenIDs: [Int] {
        lock.lock()
        let pending = _pendingTokens
        _pendingTokens = []
        lock.unlock()
        return pending.map { $0.item(Int.self) }
    }

    /// Lightweight token count — no GPU sync. Safe to call during generation
    /// for live progress estimates (e.g. context usage gauge).
    var tokenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _tokenCount
    }

    func prompt(_ prompt: MLXArray) {
        var p = upstream
        p?.prompt(prompt)
        upstream = p
    }

    func process(logits: MLXArray) -> MLXArray {
        upstream?.process(logits: logits) ?? logits
    }

    func didSample(token: MLXArray) {
        lock.lock()
        _pendingTokens.append(token)
        _tokenCount += 1
        lock.unlock()
        var p = upstream
        p?.didSample(token: token)
        upstream = p
    }
}
