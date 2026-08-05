import Foundation
import MLX
@preconcurrency import MLXLMCommon

/// Hard-excludes token IDs from sampling by zeroing their logits (−∞) before
/// the sampler runs — deterministic "next suggestion" generation, not
/// temperature gambling (see FIM_VariantPools_Arch.md §4).
///
/// Wraps the standard repetition processor so the two compose, and captures
/// the first sampled token ID (needed by callers to build the ban set for the
/// next variant — text→token round-trips are fuzzy and must not be used).
final class FIMBannedTokenProcessor: LogitProcessor, @unchecked Sendable {
    private let bannedTokenIDs: Set<Int>
    private var upstream: (any LogitProcessor)?
    private var didCaptureFirstToken = false
    private(set) var firstTokenID: Int?

    init(bannedTokenIDs: [Int], upstream: (any LogitProcessor)?) {
        self.bannedTokenIDs = Set(bannedTokenIDs)
        self.upstream = upstream
    }

    func prompt(_ prompt: MLXArray) {
        var p = upstream
        p?.prompt(prompt)
        upstream = p
    }

    func process(logits: MLXArray) -> MLXArray {
        var result = upstream?.process(logits: logits) ?? logits
        guard !bannedTokenIDs.isEmpty else { return result }
        let indices = MLXArray(bannedTokenIDs.sorted().map(Int32.init)).asType(.uint32)
        result[0..., indices] = MLXArray.full([bannedTokenIDs.count], values: MLXArray(-Float.infinity))
        return result
    }

    func didSample(token: MLXArray) {
        if !didCaptureFirstToken {
            didCaptureFirstToken = true
            firstTokenID = token.item(Int.self)
        }
        var p = upstream
        p?.didSample(token: token)
        upstream = p
    }
}
