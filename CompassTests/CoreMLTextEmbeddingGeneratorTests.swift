import XCTest
@testable import Compass

final class WordPieceTokenizerTests: XCTestCase {
    private var tokenizer: WordPieceTokenizer!

    override func setUp() async throws {
        guard let vocabURL = Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("bge-small-en-v1.5.vocab.txt") else {
            throw XCTSkip("Embedding model vocab not in test bundle")
        }
        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw XCTSkip("Vocab file not found at \(vocabURL.path)")
        }
        tokenizer = try WordPieceTokenizer(vocabURL: vocabURL)
    }

    func test_specialTokensHaveCorrectIds() {
        XCTAssertEqual(tokenizer.padId, 0, "[PAD] should be at index 0")
        XCTAssertEqual(tokenizer.unkId, 101, "[UNK] should be at index 101")
        XCTAssertEqual(tokenizer.clsId, 102, "[CLS] should be at index 102")
        XCTAssertEqual(tokenizer.sepId, 103, "[SEP] should be at index 103")
        XCTAssertEqual(tokenizer.maskId, 104, "[MASK] should be at index 104")
    }

    func test_vocabSize() {
        XCTAssertGreaterThan(tokenizer.vocabSize, 30000)
        XCTAssertLessThan(tokenizer.vocabSize, 31000)
    }

    func test_tokenToId_knownToken() {
        let id = tokenizer.tokenToId("the")
        XCTAssertNotNil(id)
        XCTAssertGreaterThan(id!, 0)
    }

    func test_tokenToId_unknownToken() {
        let id = tokenizer.tokenToId("nonexistentwordxyz")
        XCTAssertNil(id)
    }

    func test_tokenToId_specialTokens() {
        XCTAssertEqual(tokenizer.tokenToId("[CLS]"), tokenizer.clsId)
        XCTAssertEqual(tokenizer.tokenToId("[SEP]"), tokenizer.sepId)
        XCTAssertEqual(tokenizer.tokenToId("[PAD]"), tokenizer.padId)
        XCTAssertEqual(tokenizer.tokenToId("[UNK]"), tokenizer.unkId)
        XCTAssertEqual(tokenizer.tokenToId("[MASK]"), tokenizer.maskId)
    }

    func test_idToToken_roundTrip() {
        let token = "hello"
        guard let id = tokenizer.tokenToId(token) else {
            XCTFail("'hello' should be in vocab")
            return
        }
        XCTAssertEqual(tokenizer.idToToken(id), token)
    }

    func test_tokenize_simpleWords() {
        let tokens = tokenizer.tokenize("hello world")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { !$0.isEmpty })
    }

    func test_tokenize_emptyString() {
        let tokens = tokenizer.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func test_tokenize_handlesPunctuation() {
        let tokens = tokenizer.tokenize("hello, world!")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.contains("hello"))
        XCTAssertTrue(tokens.contains("world"))
    }

    func test_tokenize_handlesUppercase() {
        let tokensLower = tokenizer.tokenize("HELLO")
        let tokensUpper = tokenizer.tokenize("hello")
        XCTAssertEqual(tokensLower, tokensUpper, "Tokenizer should lowercase input")
    }

    func test_tokenize_unknownWordUsesUNK() {
        let tokens = tokenizer.tokenize("xyznonexistent12345")
        XCTAssertTrue(tokens.contains("[UNK]"), "Unknown word should produce [UNK]")
    }

    func test_tokenize_subwordSplitting() {
        let tokens = tokenizer.tokenize("unbelievable")
        let joined = tokens.joined(separator: "").replacingOccurrences(of: "##", with: "")
        XCTAssertEqual(joined, "unbelievable", "Subword tokens should reconstruct the word")
    }

    func test_tokenize_reconstructsSentence() {
        let sentence = "the cat sat on the mat"
        let tokens = tokenizer.tokenize(sentence)
        let reconstructed = tokens.joined(separator: "").replacingOccurrences(of: "##", with: "")
        XCTAssertEqual(reconstructed, sentence, "Subword tokens should reconstruct the sentence")
    }
}

final class NullEmbeddingGeneratorTests: XCTestCase {
    func test_returnsEmptyVector() async throws {
        let generator = NullEmbeddingGenerator()
        XCTAssertEqual(generator.modelIdentifier, "null")
        let vector = try await generator.generateEmbedding(for: "test")
        XCTAssertTrue(vector.isEmpty)
    }
}

final class MemoryEmbeddingGeneratorFactoryTests: XCTestCase {
    func test_discoverModels_inBundle() throws {
        guard let resourcesURL = Bundle(for: Self.self).resourceURL else {
            throw XCTSkip("No resource URL — test bundle not found")
        }
        let modelsDir = resourcesURL.appendingPathComponent("EmbeddingModels")
        guard FileManager.default.fileExists(atPath: modelsDir.path) else {
            throw XCTSkip("EmbeddingModels not in test bundle — models must be built into app bundle for RAG")
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else {
            throw XCTSkip("Could not read EmbeddingModels directory")
        }
        let modelDirs = contents.filter { $0.hasSuffix(".mlmodelc") }
        let haveVocab = contents.filter { $0.hasSuffix(".vocab.txt") }
        XCTAssertFalse(modelDirs.isEmpty, "Should have at least one .mlmodelc directory")
        XCTAssertFalse(haveVocab.isEmpty, "Should have at least one .vocab.txt file")
    }
}

final class CoreMLTextEmbeddingGeneratorIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard let resourcesURL = Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("EmbeddingModels") else {
            throw XCTSkip("EmbeddingModels not in test bundle")
        }
        let modelURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.mlmodelc")
        let vocabURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.vocab.txt")
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw XCTSkip("bge-small model not available — run ./run.sh build first")
        }
    }

    func test_loadBgeSmall() async throws {
        let resourcesURL = Bundle(for: Self.self).resourceURL!.appendingPathComponent("EmbeddingModels")
        let modelURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.mlmodelc")
        let vocabURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.vocab.txt")

        let generator = try CoreMLTextEmbeddingGenerator(
            modelName: "bge-small-en-v1.5",
            modelURL: modelURL,
            vocabURL: vocabURL
        )

        XCTAssertEqual(generator.modelIdentifier, "bge-small-en-v1.5")

        let vector = try await generator.generateEmbedding(for: "hello world")
        XCTAssertEqual(vector.count, 384)
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }

    func test_embeddingsAreSimilarForSimilarTexts() async throws {
        let resourcesURL = Bundle(for: Self.self).resourceURL!.appendingPathComponent("EmbeddingModels")
        let modelURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.mlmodelc")
        let vocabURL = resourcesURL.appendingPathComponent("bge-small-en-v1.5.vocab.txt")

        let generator = try CoreMLTextEmbeddingGenerator(
            modelName: "bge-small-en-v1.5",
            modelURL: modelURL,
            vocabURL: vocabURL
        )

        let v1 = try await generator.generateEmbedding(for: "how to sort an array in Swift")
        let v2 = try await generator.generateEmbedding(for: "sorting arrays in Swift language")
        let v3 = try await generator.generateEmbedding(for: "the weather is nice today")

        let sim12 = cosineSimilarity(v1, v2)
        let sim13 = cosineSimilarity(v1, v3)

        XCTAssertGreaterThan(sim12, sim13,
            "Similar texts should have higher cosine similarity than unrelated texts")
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var na: Float = 0
    var nb: Float = 0
    for i in a.indices {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let norm = sqrt(na) * sqrt(nb)
    return norm > 0 ? dot / norm : 0
}
