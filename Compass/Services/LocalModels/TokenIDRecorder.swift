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
final class TokenIDRecorder: LogitProcessor, @unchecked Sendable {
    private var upstream: (any LogitProcessor)?
    private let lock = NSLock()
    private var _tokenIDs: [Int] = []

    init(upstream: (any LogitProcessor)?) {
        self.upstream = upstream
    }

    var tokenIDs: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _tokenIDs
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
        _tokenIDs.append(token.item(Int.self))
        lock.unlock()
        var p = upstream
        p?.didSample(token: token)
        upstream = p
    }
}