import XCTest
import Foundation
@testable import Compass
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

/// Raw MLX baseline — bypasses the Compass wrapper entirely to measure what
/// the machine + vendor stack can actually do with Qwen3.5-4B.
@MainActor
final class RawMLXBaselineTests: XCTestCase {

    func testRawPrefillAndGenerationBaseline() async throws {
        guard LocalModelFileStore.isModelInstalled(LocalModelCatalog.chatModel) else {
            throw XCTSkip("Local chat model not downloaded")
        }
        let dir = try LocalModelFileStore.chatRuntimeModelDirectory()
        struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
            let directory: URL
            func load(from _: URL) async throws -> any MLXLMCommon.Tokenizer {
                let upstream = try await AutoTokenizer.from(modelFolder: directory)
                struct Bridge: MLXLMCommon.Tokenizer {
                    let upstream: any Tokenizers.Tokenizer
                    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
                        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
                    }
                    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
                        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
                    }
                    func convertTokenToId(_ token: String) -> Int? {
                        upstream.convertTokenToId(token)
                    }
                    func convertIdToToken(_ id: Int) -> String? {
                        upstream.convertIdToToken(id)
                    }
                    var bosToken: String? { upstream.bosToken }
                    var eosToken: String? { upstream.eosToken }
                    var unknownToken: String? { upstream.unknownToken }
                    func applyChatTemplate(
                        messages: [[String: any Sendable]],
                        tools: [[String: any Sendable]]?,
                        additionalContext: [String: any Sendable]?
                    ) throws -> [Int] {
                        try upstream.applyChatTemplate(
                            messages: messages, tools: tools,
                            additionalContext: additionalContext)
                    }
                }
                return Bridge(upstream: upstream)
            }
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: dir, using: LocalTokenizerLoader(directory: dir)
        )

        let prompt = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400)
        let start = ContinuousClock.now
        let result = try await container.perform { context async throws -> GenerateResult in
            let input = try await context.processor.prepare(input: .init(prompt: prompt))
            return try await MLXLMCommon.generate(
                input: input,
                parameters: .init(maxTokens: 80, temperature: 0.2),
                context: context
            ) { _ in .more }
        }
        let elapsedMs = Int(start.duration(to: .now).components.seconds * 1000)
        let genTps = Double(result.tokenIds.count) / max(result.generateTime, 0.001)
        print("[RAW-BASELINE] prompt_sec=\(String(format: "%.2f", result.promptTime)) gen_tokens=\(result.tokenIds.count) gen_sec=\(String(format: "%.2f", result.generateTime)) gen_tps=\(String(format: "%.1f", genTps)) wall_ms=\(elapsedMs)")
        print("[RAW-BASELINE] output: \(String(result.output.prefix(80)))")
        XCTAssertGreaterThan(result.tokenIds.count, 0)
    }
}
