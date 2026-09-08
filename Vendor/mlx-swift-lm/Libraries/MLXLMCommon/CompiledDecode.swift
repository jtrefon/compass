import MLX

/// A compiled single-token decode step for models that expose one
/// (currently: Qwen3.5 hybrid models, SSM blocks only).
///
/// The step takes token ids shaped `(1, 1)` and returns logits shaped
/// `(1, 1, vocabSize)`. SSM recurrent state is managed inside the compiled
/// graph via the ``compile(inputs:outputs:shapeless:_:)`` Updatable
/// mechanism. Attention layers (growing KV + per-step rope offsets) stay on
/// the uncompiled path; the step advances the SSM cache offsets itself so
/// reuse/trim bookkeeping stays exact.
public struct CompiledDecodeStep: @unchecked Sendable {
    public let step: (MLXArray) -> MLXArray

    public init(step: @escaping (MLXArray) -> MLXArray) {
        self.step = step
    }
}

/// Models that can build a compiled decode step bound to a concrete cache.
///
/// The cache must already hold the prefilled prompt (the step is built after
/// `prepare`). Returns nil when the model/cache cannot use the compiled path.
public protocol CompiledDecodeProviding {
    func makeCompiledDecodeStep(cache: [KVCache]) -> CompiledDecodeStep?
}

/// Bridges a `KVCache`'s state arrays into the compile Updatable mechanism.
///
/// `innerState()` returns the class-held slot arrays, so the compile tracer
/// replacement and the output write-back operate on the very arrays the
/// model layers read/write through the cache object.
public final class KVCacheUpdatable: Updatable {
    private let cache: KVCache

    public init(_ cache: KVCache) {
        self.cache = cache
    }

    public func innerState() -> [MLXArray] {
        cache.innerState()
    }
}