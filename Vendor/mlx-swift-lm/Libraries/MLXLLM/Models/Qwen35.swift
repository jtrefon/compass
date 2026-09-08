//
//  Qwen35.swift
//  mlx-swift-lm
//
//  Created by John Mai on 2026/2/9.
//
//  Port of https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/qwen3_5.py
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - Configuration

private enum RopeParametersCodingKey: String, CodingKey {
    case ropeParameters = "rope_parameters"
}

public struct Qwen35TextConfiguration: Codable, Sendable {
    var modelType: String = ""
    var hiddenSize: Int = 4096
    var hiddenLayers: Int = 32
    var intermediateSize: Int = 14336
    var attentionHeads: Int = 32
    var kvHeads: Int = 8
    var linearNumValueHeads: Int = 64
    var linearNumKeyHeads: Int = 16
    var linearKeyHeadDim: Int = 192
    var linearValueHeadDim: Int = 128
    var linearConvKernelDim: Int = 4
    var rmsNormEps: Float = 1e-6
    var vocabularySize: Int = 151_936
    var ropeTheta: Float = 100000.0
    var partialRotaryFactor: Float = 0.25
    var maxPositionEmbeddings: Int = 131072
    var tieWordEmbeddings: Bool = false
    var attentionBias: Bool = false
    var headDim: Int?
    var ropeScaling: [String: StringOrNumber]?
    var fullAttentionInterval: Int = 4

    // MoE fields
    var numExperts: Int = 0
    var numExpertsPerTok: Int = 0
    var decoderSparseStep: Int = 1
    var sharedExpertIntermediateSize: Int = 0
    var moeIntermediateSize: Int = 0
    var normTopkProb: Bool = true

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case linearNumValueHeads = "linear_num_value_heads"
        case linearNumKeyHeads = "linear_num_key_heads"
        case linearKeyHeadDim = "linear_key_head_dim"
        case linearValueHeadDim = "linear_value_head_dim"
        case linearConvKernelDim = "linear_conv_kernel_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case partialRotaryFactor = "partial_rotary_factor"
        case maxPositionEmbeddings = "max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case headDim = "head_dim"
        case ropeScaling = "rope_scaling"
        case fullAttentionInterval = "full_attention_interval"
        case numExperts = "num_experts"
        case numExpertsPerTok = "num_experts_per_tok"
        case decoderSparseStep = "decoder_sparse_step"
        case sharedExpertIntermediateSize = "shared_expert_intermediate_size"
        case moeIntermediateSize = "moe_intermediate_size"
        case normTopkProb = "norm_topk_prob"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultRopeParameters: [String: StringOrNumber] = [
            "type": .string("default"),
            "mrope_section": .ints([11, 11, 10]),
            "rope_theta": .float(100000.0),
            "partial_rotary_factor": .float(0.25),
        ]

        self.modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? ""
        self.hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 4096
        self.hiddenLayers = try container.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 32
        self.intermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 14336
        self.attentionHeads = try container.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 32
        self.kvHeads = try container.decodeIfPresent(Int.self, forKey: .kvHeads) ?? 8
        self.linearNumValueHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumValueHeads) ?? 64
        self.linearNumKeyHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumKeyHeads) ?? 16
        self.linearKeyHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearKeyHeadDim) ?? 192
        self.linearValueHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearValueHeadDim) ?? 128
        self.linearConvKernelDim =
            try container.decodeIfPresent(Int.self, forKey: .linearConvKernelDim) ?? 4
        self.rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        self.vocabularySize =
            try container.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? 151_936
        self.maxPositionEmbeddings =
            try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        self.tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        self.attentionBias =
            try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        self.headDim = try container.decodeIfPresent(Int.self, forKey: .headDim)
        self.fullAttentionInterval =
            try container.decodeIfPresent(Int.self, forKey: .fullAttentionInterval) ?? 4

        // MoE fields
        self.numExperts = try container.decodeIfPresent(Int.self, forKey: .numExperts) ?? 0
        self.numExpertsPerTok =
            try container.decodeIfPresent(Int.self, forKey: .numExpertsPerTok) ?? 0
        self.decoderSparseStep =
            try container.decodeIfPresent(Int.self, forKey: .decoderSparseStep) ?? 1
        self.sharedExpertIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .sharedExpertIntermediateSize) ?? 0
        self.moeIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .moeIntermediateSize) ?? 0
        self.normTopkProb = try container.decodeIfPresent(Bool.self, forKey: .normTopkProb) ?? true

        let ropeContainer = try decoder.container(keyedBy: RopeParametersCodingKey.self)
        let ropeParameters = try ropeContainer.decodeIfPresent(
            [String: StringOrNumber].self, forKey: .ropeParameters)

        if var ropeParameters {
            if ropeParameters["type"] == nil, let ropeType = ropeParameters["rope_type"] {
                ropeParameters["type"] = ropeType
            }
            self.ropeTheta = ropeParameters["rope_theta"]?.asFloat() ?? 100000.0
            self.partialRotaryFactor =
                ropeParameters["partial_rotary_factor"]?.asFloat() ?? 0.25
            self.ropeScaling = ropeParameters
        } else {
            self.ropeTheta =
                try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 100000.0
            self.partialRotaryFactor =
                try container.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 0.25
            self.ropeScaling =
                try container.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling)
                ?? defaultRopeParameters
        }

        if self.headDim == nil {
            self.headDim = self.hiddenSize / self.attentionHeads
        }
    }
}

// MARK: - GatedDeltaNet

final class Qwen35GatedDeltaNet: Module {
    let hiddenSize: Int
    let numVHeads: Int
    let numKHeads: Int
    let headKDim: Int
    let headVDim: Int
    let keyDim: Int
    let valueDim: Int
    let convKernelSize: Int
    let convDim: Int

    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "in_proj_qkv") var inProjQKV: Linear
    @ModuleInfo(key: "in_proj_z") var inProjZ: Linear
    @ModuleInfo(key: "in_proj_b") var inProjB: Linear
    @ModuleInfo(key: "in_proj_a") var inProjA: Linear

    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray

    @ModuleInfo(key: "norm") var norm: Qwen3NextRMSNormGated
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ args: Qwen35TextConfiguration) {
        self.hiddenSize = args.hiddenSize
        self.numVHeads = args.linearNumValueHeads
        self.numKHeads = args.linearNumKeyHeads
        self.headKDim = args.linearKeyHeadDim
        self.headVDim = args.linearValueHeadDim
        self.keyDim = headKDim * numKHeads
        self.valueDim = headVDim * numVHeads
        self.convKernelSize = args.linearConvKernelDim
        self.convDim = keyDim * 2 + valueDim

        precondition(
            numVHeads % numKHeads == 0,
            "num_v_heads (\(numVHeads)) must be divisible by num_k_heads (\(numKHeads))"
        )

        _conv1d.wrappedValue = Conv1d(
            inputChannels: convDim,
            outputChannels: convDim,
            kernelSize: convKernelSize,
            stride: 1,
            padding: 0,
            dilation: 1,
            groups: convDim,
            bias: false
        )

        _inProjQKV.wrappedValue = Linear(hiddenSize, keyDim * 2 + valueDim, bias: false)
        _inProjZ.wrappedValue = Linear(hiddenSize, valueDim, bias: false)
        _inProjB.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)
        _inProjA.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)

        _dtBias.wrappedValue = MLXArray.ones([numVHeads])
        let a = MLXRandom.uniform(low: 0, high: 16, [numVHeads])
        _aLog.wrappedValue = log(a)

        _norm.wrappedValue = Qwen3NextRMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)
        _outProj.wrappedValue = Linear(valueDim, hiddenSize, bias: false)

        super.init()
    }

    func callAsFunction(
        _ inputs: MLXArray,
        mask: MLXArray? = nil,
        cache: MambaCache? = nil
    ) -> MLXArray {
        let B = inputs.dim(0)
        let S = inputs.dim(1)

        var qkv = inProjQKV(inputs)
        let z = inProjZ(inputs).reshaped(B, S, numVHeads, headVDim)
        let b = inProjB(inputs)
        let a = inProjA(inputs)

        let convState: MLXArray
        if let cacheState = cache?[0] {
            convState = cacheState
        } else {
            convState = MLXArray.zeros([B, convKernelSize - 1, convDim], dtype: inputs.dtype)
        }

        if let mask {
            qkv = MLX.where(mask[.ellipsis, .newAxis], qkv, 0)
        }

        let convInput = concatenated([convState, qkv], axis: 1)
        if let cache {
            cache[0] = contiguous(convInput[0..., (-(convKernelSize - 1))..., 0...])
        }

        let convOut = silu(conv1d(convInput))

        let convSplit = MLX.split(convOut, indices: [keyDim, 2 * keyDim], axis: -1)
        let q = convSplit[0].reshaped(B, S, numKHeads, headKDim)
        let k = convSplit[1].reshaped(B, S, numKHeads, headKDim)
        let v = convSplit[2].reshaped(B, S, numVHeads, headVDim)

        var state = cache?[1]
        let dtype = q.dtype
        let invScale = pow(Float(headKDim), -0.5)
        let qNormed =
            MLXArray(pow(invScale, 2), dtype: dtype)
            * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
        let kNormed =
            MLXArray(invScale, dtype: dtype)
            * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

        var out: MLXArray

        (out, state) = gatedDeltaUpdate(
            q: qNormed,
            k: kNormed,
            v: v,
            a: a,
            b: b,
            aLog: aLog,
            dtBias: dtBias,
            state: state,
            mask: mask
        )

        if let cache {
            cache[1] = state
            cache.advance(S)
        }

        out = norm(out, gate: z)
        return outProj(out.reshaped(B, S, -1))
    }
}

// MARK: - Attention

final class Qwen35Attention: Module {
    let attentionHeads: Int
    let kvHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPELayer

    init(_ args: Qwen35TextConfiguration) {
        let headDim = args.headDim ?? (args.hiddenSize / args.attentionHeads)
        self.attentionHeads = args.attentionHeads
        self.kvHeads = args.kvHeads
        self.scale = pow(Float(headDim), -0.5)

        _qProj.wrappedValue = Linear(
            args.hiddenSize, args.attentionHeads * headDim * 2, bias: args.attentionBias)
        _kProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias)
        _vProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias)
        _oProj.wrappedValue = Linear(
            args.attentionHeads * headDim, args.hiddenSize, bias: args.attentionBias)

        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        let ropeDims = Int(Float(headDim) * args.partialRotaryFactor)
        self.rope = initializeRope(
            dims: max(1, ropeDims),
            base: args.ropeTheta,
            traditional: false,
            scalingConfig: args.ropeScaling,
            maxPositionEmbeddings: args.maxPositionEmbeddings
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        let qProjOutput = qProj(x)
        let qSplit = qProjOutput.reshaped(B, L, attentionHeads, -1).split(parts: 2, axis: -1)
        var queries = qSplit[0]
        let gate = qSplit[1].reshaped(B, L, -1)

        var keys = kProj(x)
        var values = vProj(x)

        queries = qNorm(queries).transposed(0, 2, 1, 3)
        keys = kNorm(keys.reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return oProj(sigmoidMultiply(output, gate))
    }

    /// Attention computation for the compiled decode path. Instead of using
    /// the cache object (which has Swift-side offset state and pre-allocated
    /// buffers), this takes the valid cached K/V as direct inputs and returns
    /// the updated K/V (old + new concatenated) as outputs. The caller
    /// maintains the K/V arrays and offset outside the compiled graph.
    ///
    /// This enables `MLX.compile(shapeless: true)` to trace the entire
    /// attention layer once and reuse the compiled graph every token,
    /// eliminating per-token graph construction for Q/K/V projections,
    /// norms, RoPE, SDPA, and the output projection.
    func compiledAttention(
        _ x: MLXArray,
        offset: MLXArray,
        cachedKeys: MLXArray,
        cachedValues: MLXArray
    ) -> (output: MLXArray, keys: MLXArray, values: MLXArray) {
        let B = x.dim(0)
        let L = x.dim(1)

        let qProjOutput = qProj(x)
        let qSplit = qProjOutput.reshaped(B, L, attentionHeads, -1).split(parts: 2, axis: -1)
        let queries = qSplit[0]
        let gate = qSplit[1].reshaped(B, L, -1)

        let keys = kProj(x)
        let values = vProj(x)

        let queriesNormed = qNorm(queries).transposed(0, 2, 1, 3)
        let keysNormed = kNorm(keys.reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        let valuesTransposed = values.reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let queriesRope = applyRotaryPosition(rope, to: queriesNormed, offset: .batch(offset))
        let keysRope = applyRotaryPosition(rope, to: keysNormed, offset: .batch(offset))

        let allKeys = concatenated([cachedKeys, keysRope], axis: 2)
        let allValues = concatenated([cachedValues, valuesTransposed], axis: 2)

        let output = MLXFast.scaledDotProductAttention(
            queries: queriesRope,
            keys: allKeys,
            values: allValues,
            scale: scale,
            mask: .none
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        let result = oProj(sigmoidMultiply(output, gate))
        return (result, allKeys, allValues)
    }
}

// MARK: - SparseMoeBlock

final class Qwen35SparseMoeBlock: Module, UnaryLayer {
    let normTopkProb: Bool
    let numExperts: Int
    let topK: Int

    @ModuleInfo(key: "gate") var gate: Linear
    @ModuleInfo(key: "switch_mlp") var switchMLP: SwitchGLU

    @ModuleInfo(key: "shared_expert") var sharedExpert: Qwen3NextMLP
    @ModuleInfo(key: "shared_expert_gate") var sharedExpertGate: Linear

    init(_ args: Qwen35TextConfiguration) {
        self.normTopkProb = args.normTopkProb
        self.numExperts = args.numExperts
        self.topK = args.numExpertsPerTok

        _gate.wrappedValue = Linear(args.hiddenSize, args.numExperts, bias: false)
        _switchMLP.wrappedValue = SwitchGLU(
            inputDims: args.hiddenSize,
            hiddenDims: args.moeIntermediateSize,
            numExperts: args.numExperts
        )

        _sharedExpert.wrappedValue = Qwen3NextMLP(
            dimensions: args.hiddenSize,
            hiddenDimensions: args.sharedExpertIntermediateSize
        )
        _sharedExpertGate.wrappedValue = Linear(args.hiddenSize, 1, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var gates = gate(x)
        gates = MLX.softmax(gates, axis: -1, precise: true)

        let k = topK
        let kth = gates.dim(-1) - k
        let inds = MLX.argPartition(gates, kth: kth, axis: -1)[.ellipsis, (kth)...]
        var scores = MLX.takeAlong(gates, inds, axis: -1)
        if normTopkProb {
            scores = scores / scores.sum(axis: -1, keepDims: true)
        }

        let y = switchMLP(x, inds)
        let combined = weightedExpertSum(y, scores)

        var sharedY = sharedExpert(x)
        sharedY = sigmoid(sharedExpertGate(x)) * sharedY

        return combined + sharedY
    }
}

// MARK: - Decoder Layer

final class Qwen35DecoderLayer: Module {
    let isLinear: Bool

    @ModuleInfo(key: "self_attn") var selfAttn: Qwen35Attention?
    @ModuleInfo(key: "linear_attn") var linearAttn: Qwen35GatedDeltaNet?

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    @ModuleInfo(key: "mlp") var mlp: Module

    init(_ args: Qwen35TextConfiguration, layerIdx: Int) {
        self.isLinear = (layerIdx + 1) % args.fullAttentionInterval != 0

        if isLinear {
            _linearAttn.wrappedValue = Qwen35GatedDeltaNet(args)
        } else {
            _selfAttn.wrappedValue = Qwen35Attention(args)
        }

        if args.numExperts > 0 {
            _mlp.wrappedValue = Qwen35SparseMoeBlock(args)
        } else {
            _mlp.wrappedValue = Qwen3NextMLP(
                dimensions: args.hiddenSize,
                hiddenDimensions: args.intermediateSize
            )
        }

        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?
    ) -> MLXArray {
        let r: MLXArray
        if isLinear {
            r = linearAttn!(inputLayerNorm(x), mask: ssmMask, cache: cache as? MambaCache)
        } else {
            r = selfAttn!(inputLayerNorm(x), mask: attentionMask, cache: cache)
        }

        let h = x + r
        return h + (mlp as! UnaryLayer)(postAttentionLayerNorm(h))
    }

    /// Compiled-decode entry point for full-attention layers.
    ///
    /// Instead of dispatching through `selfAttn` (which mutates the
    /// `KVCache` object's Swift-side state and pre-allocated buffers),
    /// this routes through `Qwen35Attention.compiledAttention`, which
    /// treats the cached K/V as direct inputs and returns the updated
    /// K/V as outputs. The caller maintains the K/V arrays and the
    /// monotonic offset outside the compiled graph.
    ///
    /// The MLP, residual, and norm work are pure tensor ops and safe
    /// to include in the compiled closure.
    func compiledAttentionCall(
        _ x: MLXArray,
        offset: MLXArray,
        cachedKeys: MLXArray,
        cachedValues: MLXArray
    ) -> (hidden: MLXArray, keys: MLXArray, values: MLXArray) {
        let normed = inputLayerNorm(x)
        let (attnOut, keys, values) = selfAttn!.compiledAttention(
            normed, offset: offset, cachedKeys: cachedKeys, cachedValues: cachedValues)
        let h = x + attnOut
        let hidden = h + (mlp as! UnaryLayer)(postAttentionLayerNorm(h))
        return (hidden, keys, values)
    }
}

// MARK: - Text Model

public class Qwen35TextModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [Qwen35DecoderLayer]
    let norm: RMSNorm

    let ssmIdx: Int
    let faIdx: Int

    init(_ args: Qwen35TextConfiguration) {
        precondition(args.vocabularySize > 0)

        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize,
            dimensions: args.hiddenSize
        )

        self.layers = (0 ..< args.hiddenLayers).map { layerIdx in
            Qwen35DecoderLayer(args, layerIdx: layerIdx)
        }

        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)

        self.ssmIdx = 0
        self.faIdx = args.fullAttentionInterval - 1

        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache?]? = nil) -> MLXArray {
        var hiddenStates = embedTokens(inputs)

        var cacheArray = cache
        if cacheArray == nil {
            cacheArray = Array(repeating: nil as KVCache?, count: layers.count)
        }

        let faMask = createAttentionMask(h: hiddenStates, cache: cacheArray?[faIdx])
        let ssmMask = createSSMMask(h: hiddenStates, cache: cacheArray?[ssmIdx] as? MambaCache)

        for (i, layer) in layers.enumerated() {
            let mask = layer.isLinear ? ssmMask : nil
            let attnMask =
                layer.isLinear
                ? MLXFast.ScaledDotProductAttentionMaskMode.none : faMask
            hiddenStates = layer(
                hiddenStates, attentionMask: attnMask, ssmMask: mask, cache: cacheArray?[i])
        }

        return norm(hiddenStates)
    }
}

public class Qwen35TextModel: Module, LLMModel, KVCacheDimensionProvider {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    public let model: Qwen35TextModelInner
    let configuration: Qwen35TextConfiguration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ args: Qwen35TextConfiguration) {
        self.configuration = args
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.model = Qwen35TextModelInner(args)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var out = model(inputs, cache: cache)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return out
    }

    public func prefillStep(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?)
        -> LMOutput.State?
    {
        _ = model(input.tokens, cache: cache)
        return nil
    }

    public func newCache(parameters: GenerateParameters?) -> [KVCache] {
        let attentionCache = Qwen35TextModel.makeAttentionCache(parameters: parameters)
        return model.layers.map { layer in
            if layer.isLinear {
                return MambaCache()
            }
            return attentionCache.copy()
        }
    }

    /// Build the attention KV cache for a single full-attention layer, honoring
    /// ``GenerateParameters`` memory controls. The GatedDelta (linear) recurrent
    /// states are not windowed or quantized — they are fixed-size per-token states.
    ///
    /// When both quantization and a window are requested, a bounded
    /// ``QuantizedKVCache`` is used (memory-efficient with a capped window).
    /// Quantization without a window is unbounded. Without quantization, a
    /// ``RotatingKVCache`` is used when a window is set.
    private static func makeAttentionCache(parameters: GenerateParameters?) -> any KVCache {
        let maxKVSize = parameters?.maxKVSize

        if let (bits, groupSize) = resolveAttentionCacheQuantization(parameters),
            parameters?.quantizedKVStart == 0
        {
            return QuantizedKVCache(groupSize: groupSize, bits: bits, maxSize: maxKVSize)
        }

        if let maxKVSize {
            return RotatingKVCache(maxSize: maxKVSize, keep: 4)
        }

        return KVCacheSimple()
    }

    private static func resolveAttentionCacheQuantization(_ parameters: GenerateParameters?)
        -> (bits: Int, groupSize: Int)?
    {
        if let scheme = parameters?.kvScheme, let resolved = resolveAffineScheme(scheme) {
            return resolved
        }
        if let bits = parameters?.kvBits {
            return (bits, parameters?.kvGroupSize ?? 64)
        }
        return nil
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let hasMTPWeights = weights.keys.contains { $0.contains("mtp.") }
        let hasUnsanitizedConv1d = weights.contains { key, value in
            key.contains("conv1d.weight") && value.dim(-1) != 1
        }
        let shouldShiftNormWeights = hasMTPWeights || hasUnsanitizedConv1d

        var weights = weights.filter { !$0.key.contains("mtp.") }

        if configuration.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }

        let normKeys = [
            ".input_layernorm.weight",
            ".post_attention_layernorm.weight",
            "model.norm.weight",
            ".q_norm.weight",
            ".k_norm.weight",
        ]

        for k in Array(weights.keys) {
            guard let v = weights[k] else { continue }
            if k.contains("conv1d.weight") && v.dim(-1) != 1 {
                weights[k] = v.movedAxis(source: 2, destination: 1)
                continue
            }
            if shouldShiftNormWeights
                && normKeys.contains(where: { k.hasSuffix($0) })
                && v.ndim == 1
            {
                weights[k] = v + MLXArray(1, dtype: v.dtype)
            }
        }

        return weights
    }
}

extension Qwen35TextModel: LoRAModel {
    public var loraLayers: [Module] {
        model.layers
    }
}

// MARK: - Top-level Model

public class Qwen35Model: Module, LLMModel, KVCacheDimensionProvider {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    @ModuleInfo(key: "language_model") var languageModel: Qwen35TextModel

    public init(_ args: Qwen35Configuration) {
        let textModel = Qwen35TextModel(args.textConfig)
        self.vocabularySize = textModel.vocabularySize
        self.kvHeads = textModel.kvHeads
        _languageModel.wrappedValue = textModel
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    public func prefillStep(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?)
        -> LMOutput.State?
    {
        languageModel.prefillStep(input, cache: cache, state: state)
    }

    public func newCache(parameters: GenerateParameters?) -> [KVCache] {
        languageModel.newCache(parameters: parameters)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = [String: MLXArray]()
        for (key, value) in weights {
            if key.hasPrefix("vision_tower") || key.hasPrefix("model.visual") {
                continue
            }

            var key = key
            if key.hasPrefix("model.language_model") {
                key = key.replacingOccurrences(
                    of: "model.language_model", with: "language_model.model")
            } else if !key.hasPrefix("language_model.") {
                key = "language_model." + key
            }
            sanitized[key] = value
        }

        return languageModel.sanitize(weights: sanitized)
    }
}

extension Qwen35Model: LoRAModel {
    public var loraLayers: [Module] {
        languageModel.model.layers
    }
}

// MARK: - Compiled decode (SSM + attention blocks)

extension Qwen35TextModel: CompiledDecodeProviding {
    /// Builds a compiled single-token decode step bound to the given cache
    /// (which must already hold the prefilled prompt).
    ///
    /// Both SSM (GatedDeltaNet) blocks AND full-attention blocks are compiled.
    ///
    /// SSM blocks: grouped runs of consecutive linear layers. Their state
    /// (conv + recurrent) is constant-shape and offset-free, so the compiled
    /// graph never needs a re-trace. State is managed via the ``compile``
    /// Updatable mechanism.
    ///
    /// Attention blocks: each full-attention layer is compiled with
    /// `shapeless: true`. The cached K/V arrays are passed as direct inputs
    /// (not through the cache object), and the updated K/V (old + new
    /// concatenated) are returned as outputs. The caller maintains the K/V
    /// arrays in Swift and writes them back to the cache object after each
    /// step so cache reuse, trimming, and persistence remain exact.
    ///
    /// The attention compiled path is only used when:
    /// - The cache is NOT quantized (`KVCacheSimple` or `RotatingKVCache`)
    /// - The cache has not wrapped (`offset < maxSize` for `RotatingKVCache`)
    ///
    /// For quantized caches or wrapped rotating caches, attention layers
    /// fall back to the uncompiled path.
    public func makeCompiledDecodeStep(cache: [KVCache]) -> CompiledDecodeStep? {
        let layers = model.layers
        guard cache.count == layers.count else { return nil }
        guard layers.contains(where: \.isLinear) else { return nil }

        // ---- SSM groups (consecutive linear layers) ----
        var groups: [(start: Int, end: Int)] = []
        var i = 0
        while i < layers.count {
            if layers[i].isLinear {
                let start = i
                while i < layers.count && layers[i].isLinear { i += 1 }
                groups.append((start, i))
            } else {
                i += 1
            }
        }

        let mambaIndices = layers.indices.filter { layers[$0].isLinear }
        let mambaCaches = mambaIndices.map { cache[$0] as! MambaCache }
        let offsetsBeforeTrace = mambaCaches.map { $0.offset }

        var compiledFns: [Int: @Sendable ([MLXArray]) -> [MLXArray]] = [:]
        var groupEnds: [Int: Int] = [:]
        for group in groups {
            let groupLayers = Array(layers[group.start ..< group.end])
            let groupCaches = groupLayers.indices.map { cache[group.start + $0] as! MambaCache }
            let updatables = groupCaches.map { KVCacheUpdatable($0) }
            let fn = MLX.compile(
                inputs: updatables,
                outputs: updatables,
                shapeless: false
            ) { args in
                var h = args[0]
                for (layer, c) in zip(groupLayers, groupCaches) {
                    h = layer(h, attentionMask: .none, ssmMask: nil, cache: c)
                }
                return [h]
            }
            compiledFns[group.start] = fn
            groupEnds[group.start] = group.end
        }

        for (c, offset) in zip(mambaCaches, offsetsBeforeTrace) {
            c.offset = offset
        }

        // ---- Attention compilation ----
        // For each full-attention layer with a non-quantized cache, build a
        // shapeless compiled function that takes [hidden, offset, cachedK,
        // cachedV] and returns [hidden, keys, values]. The K/V arrays are
        // maintained outside the compiled graph and written back to the cache
        // after each step.
        let attentionIndices = layers.indices.filter { !layers[$0].isLinear }

        var attnKV: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var attnCompiled: [Int: @Sendable ([MLXArray]) -> [MLXArray]] = [:]
        var attnMaxSize: [Int: Int] = [:]

        for idx in attentionIndices {
            let c = cache[idx]
            if c is QuantizedKVCacheProtocol { continue }
            let state = c.state
            guard state.count >= 2 else { continue }
            attnKV[idx] = (state[0], state[1])
            if let maxSize = c.maxSize { attnMaxSize[idx] = maxSize }

            let layer = layers[idx]
            let fn = MLX.compile(
                inputs: [], outputs: [], shapeless: true
            ) { args in
                let (h, keys, values) = layer.compiledAttentionCall(
                    args[0], offset: args[1],
                    cachedKeys: args[2], cachedValues: args[3]
                )
                return [h, keys, values]
            }
            attnCompiled[idx] = fn
        }

        let inner = model
        let head = lmHead
        var cacheMut = cache
        let step = CompiledDecodeStep { tokens in
            var h = inner.embedTokens(tokens)
            var idx = 0
            while idx < layers.count {
                if let fn = compiledFns[idx], let end = groupEnds[idx] {
                    h = fn([h])[0]
                    idx = end
                } else if let fn = attnCompiled[idx], var kv = attnKV[idx] {
                    let offset = cacheMut[idx].offset
                    if let maxSize = attnMaxSize[idx], offset >= maxSize {
                        attnCompiled[idx] = nil
                        h = layers[idx](h, attentionMask: .none, ssmMask: nil, cache: cacheMut[idx])
                        idx += 1
                        continue
                    }
                    let offsetArr = MLXArray(Int32(offset))
                    let results = fn([h, offsetArr, kv.keys, kv.values])
                    h = results[0]
                    kv.keys = results[1]
                    kv.values = results[2]
                    attnKV[idx] = kv
                    cacheMut[idx].state = [kv.keys, kv.values]
                    (cacheMut[idx] as! BaseKVCache).offset = offset + 1
                    idx += 1
                } else {
                    h = layers[idx](h, attentionMask: .none, ssmMask: nil, cache: cacheMut[idx])
                    idx += 1
                }
            }
            h = inner.norm(h)
            let logits: MLXArray
            if let head {
                logits = head(h)
            } else {
                logits = inner.embedTokens.asLinear(h)
            }
            for c in mambaCaches {
                c.advance(1)
            }
            return logits
        }
        return step
    }
}
