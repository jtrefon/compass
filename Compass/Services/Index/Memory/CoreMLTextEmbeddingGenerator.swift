import Foundation
import CoreML

private func elapsedMs(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

public final class CoreMLTextEmbeddingGenerator: MemoryEmbeddingGenerating {
    public let modelIdentifier: String
    private let wrapper: MLModelWrapper
    private let tokenizer: WordPieceTokenizer
    /// Real embedding dimension of the compiled model (validated against the FAISS index).
    public let embeddingDim: Int
    private let maxTokens: Int

    public init(
        modelName: String,
        modelURL: URL,
        vocabURL: URL,
        maxTokens: Int = 128,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) throws {
        let initStart = Date()
        self.modelIdentifier = modelName
        self.maxTokens = maxTokens

        self.tokenizer = try WordPieceTokenizer(vocabURL: vocabURL)

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let loadStart = Date()
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        self.wrapper = MLModelWrapper(model)

        guard let outputShape = model.modelDescription.outputDescriptionsByName.first?.value.multiArrayConstraint?.shape else {
            throw EmbeddingError.invalidModel("No output shape found")
        }
        self.embeddingDim = outputShape.last?.intValue ?? 384
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        let tokens = tokenizer.tokenize(text)
        let inputIds = buildInputIds(tokens)
        let attentionMask = buildAttentionMask(tokenCount: tokens.count)
        // Move the blocking CoreML prediction to a dedicated utility queue so
        // it does not stall the caller's executor (actor, MainActor, etc.).
        let wrapper = self.wrapper
        let pInputIds = inputIds
        let pAttentionMask = attentionMask
        let pMaxTokens = maxTokens
        return try await Task.detached(priority: .utility) {
            try CoreMLTextEmbeddingGenerator.predict(
                wrapper: wrapper,
                inputIds: pInputIds,
                attentionMask: pAttentionMask,
                maxTokens: pMaxTokens
            )
        }.value
    }

    /// Static, Sendable-safe prediction. All inputs are value types.
    /// Called from a utility Task so the caller's executor is never blocked.
    private static func predict(
        wrapper: MLModelWrapper,
        inputIds: [Int32],
        attentionMask: [Int32],
        maxTokens: Int
    ) throws -> [Float] {
        let inputArray = try MLMultiArray(shape: [1, maxTokens] as [NSNumber], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, maxTokens] as [NSNumber], dataType: .int32)
        let typeArray = try MLMultiArray(shape: [1, maxTokens] as [NSNumber], dataType: .int32)

        for i in 0..<maxTokens {
            inputArray[i] = NSNumber(value: i < inputIds.count ? inputIds[i] : 0)
            maskArray[i] = NSNumber(value: i < attentionMask.count ? attentionMask[i] : 0)
            typeArray[i] = NSNumber(value: 0)
        }

        let inputFeatures: [String: Any] = [
            "input_ids": inputArray,
            "attention_mask": maskArray,
            "token_type_ids": typeArray
        ]

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputFeatures) else {
            throw EmbeddingError.inferenceFailed("Failed to create input provider")
        }

        let output = try wrapper.model.prediction(from: provider)

        guard let outputName = output.featureNames.first,
              let outputMultiArray = output.featureValue(for: outputName)?.multiArrayValue else {
            throw EmbeddingError.inferenceFailed("No output from model")
        }

        let seqLen = outputMultiArray.shape[1].intValue
        let dim = outputMultiArray.shape[2].intValue
        var pooled = [Float](repeating: 0, count: dim)
        var tokenCount: Float = 0

        for i in 0..<seqLen {
            guard i < attentionMask.count, attentionMask[i] == 1 else { continue }
            tokenCount += 1
            for j in 0..<dim {
                let idx = i * dim + j
                pooled[j] += outputMultiArray[idx].floatValue
            }
        }

        if tokenCount > 0 {
            for j in 0..<dim { pooled[j] /= tokenCount }
        }

        normalizeInPlace(&pooled)
        return pooled
    }

    private func buildInputIds(_ tokens: [String]) -> [Int32] {
        let ids = tokens.prefix(maxTokens - 2)
        var result = [Int32]()
        result.append(Int32(tokenizer.clsId))
        for token in ids {
            result.append(Int32(tokenizer.tokenToId(token) ?? tokenizer.unkId))
        }
        result.append(Int32(tokenizer.sepId))
        while result.count < maxTokens {
            result.append(Int32(tokenizer.padId))
        }
        return Array(result.prefix(maxTokens))
    }

    private func buildAttentionMask(tokenCount: Int) -> [Int32] {
        let effectiveTokens = min(tokenCount, maxTokens - 2) + 2
        var mask = [Int32](repeating: 0, count: maxTokens)
        for i in 0..<min(effectiveTokens, maxTokens) {
            mask[i] = 1
        }
        return mask
    }

    private static func normalizeInPlace(_ vector: inout [Float]) {
        let sumSquares = vector.reduce(Float(0)) { $0 + $1 * $1 }
        guard sumSquares > 0 else { return }
        let norm = sqrt(sumSquares)
        for i in vector.indices {
            vector[i] /= norm
        }
    }
}

public struct WordPieceTokenizer: Sendable {
    private let vocab: [String: Int]
    private let idsToTokens: [Int: String]
    public let padId: Int
    public let unkId: Int
    public let clsId: Int
    public let sepId: Int
    public let maskId: Int
    public let vocabSize: Int

    public init(vocabURL: URL) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var vocab: [String: Int] = [:]
        var idsToTokens: [Int: String] = [:]

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            vocab[trimmed] = index
            idsToTokens[index] = trimmed
        }

        self.vocab = vocab
        self.idsToTokens = idsToTokens
        self.vocabSize = vocab.count
        self.padId = vocab["[PAD]"] ?? 0
        self.unkId = vocab["[UNK]"] ?? 101
        self.clsId = vocab["[CLS]"] ?? 102
        self.sepId = vocab["[SEP]"] ?? 103
        self.maskId = vocab["[MASK]"] ?? 104
    }

    public func tokenToId(_ token: String) -> Int? {
        vocab[token]
    }

    public func idToToken(_ id: Int) -> String? {
        idsToTokens[id]
    }

    public func tokenize(_ text: String) -> [String] {
        let normalized = text.lowercased()
        let words = splitIntoWords(normalized)
        return words.flatMap { wordpiece($0) }
    }

    private func splitIntoWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber || char == "'" || char == "-" {
                current.append(char)
            } else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                if !char.isWhitespace {
                    words.append(String(char))
                }
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func wordpiece(_ word: String) -> [String] {
        if vocab[word] != nil {
            return [word]
        }

        var tokens: [String] = []
        var start = word.startIndex

        while start < word.endIndex {
            var end = word.endIndex
            var found = false
            var bestLen = 0

            while end > start {
                let sub = word[start..<end]
                let piece = start == word.startIndex ? String(sub) : "##" + sub

                if vocab[piece] != nil {
                    if sub.count > bestLen {
                        bestLen = sub.count
                    }
                    found = true
                    tokens.append(piece)
                    start = end
                    break
                }
                end = word.index(before: end)
            }

            if !found {
                tokens.append("[UNK]")
                break
            }
        }

        return tokens
    }
}

public enum EmbeddingError: Error, LocalizedError {
    case invalidModel(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let msg): return "Invalid embedding model: \(msg)"
        case .inferenceFailed(let msg): return "Embedding inference failed: \(msg)"
        }
    }
}

final class MLModelWrapper: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}
