import XCTest
import Foundation
import Darwin
@testable import Compass
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers

/// Process RSS via task_info — usable from any thread (Sendable).
@Sendable
func currentProcessRSSMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int(info.resident_size / 1024 / 1024)
}

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
        let configs: [(label: String, maxKV: Int?, kvBits: Int?, penalty: Float?, penCtx: Int)] = [
            ("baseline", nil, nil, nil, 0),
            ("+repPenalty", nil, nil, 1.05, 64),
            ("+4bitKV", nil, 4, nil, 0),
            ("+repPenalty+4bitKV", nil, 4, 1.05, 64),
            ("pipeline-130k-4bit", 132_096, 4, 1.05, 64)
        ]
        for config in configs {
            let start = ContinuousClock.now
            let result = try await container.perform { context async throws -> GenerateResult in
                let input = try await context.processor.prepare(input: .init(prompt: prompt))
                return try await MLXLMCommon.generate(
                    input: input,
                    parameters: .init(
                        maxTokens: 80, maxKVSize: config.maxKV, kvBits: config.kvBits,
                        temperature: 0.2, topP: 0.9,
                        repetitionPenalty: config.penalty,
                        repetitionContextSize: config.penCtx,
                        prefillStepSize: 512
                    ),
                    context: context
                ) { _ in .more }
            }
            let elapsedMs = Int(start.duration(to: .now).components.seconds * 1000)
            let genTps = Double(result.tokenIds.count) / max(result.generateTime, 0.001)
            let promptTps = Double(400 * 9) / max(result.promptTime, 0.001)
            print("[RAW-BASELINE] \(config.label): prompt_sec=\(String(format: "%.2f", result.promptTime)) prompt_tps=\(String(format: "%.0f", promptTps)) gen_tokens=\(result.tokenIds.count) gen_sec=\(String(format: "%.2f", result.generateTime)) gen_tps=\(String(format: "%.1f", genTps)) wall_ms=\(elapsedMs)")
            XCTAssertGreaterThan(result.tokenIds.count, 0)
        }

        // Long-context scaling: measure decode tps with a 30K-token prefix in
        // the cache (mirrors live session context) — 4-bit vs FP16 KV.
        let longPrompt = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3333)  // ~30K tokens
        for (label, kvBits) in [("fp16-30k", nil as Int?), ("4bit-30k", 4 as Int?)] {
            let start = ContinuousClock.now
            let result = try await container.perform { context async throws -> GenerateResult in
                let input = try await context.processor.prepare(input: .init(prompt: longPrompt))
                return try await MLXLMCommon.generate(
                    input: input,
                    parameters: .init(
                        maxTokens: 40, maxKVSize: 132_096, kvBits: kvBits,
                        temperature: 0.2, topP: 0.9,
                        repetitionPenalty: 1.05, repetitionContextSize: 64,
                        prefillStepSize: 512
                    ),
                    context: context
                ) { _ in .more }
            }
            let elapsedMs = Int(start.duration(to: .now).components.seconds * 1000)
            let genTps = Double(result.tokenIds.count) / max(result.generateTime, 0.001)
            print("[RAW-BASELINE] \(label): prefill_sec=\(String(format: "%.1f", result.promptTime)) gen_tps=\(String(format: "%.1f", genTps)) wall_ms=\(elapsedMs)")
            XCTAssertGreaterThan(result.tokenIds.count, 0)
        }
    }

    /// Microbenchmark: isolate the per-token decode ATTENTION cost on a
    /// prefilled 30K cache, comparing the q4 quantizedMM path vs a fp16
    /// fused-SDPA path on the SAME cache content. This distinguishes
    /// "quantized matmul is slow" from "materialized O(T) scores are slow".
    func testDecodeAttentionPathMicrobenchmark() async throws {
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
        // 30K-token context
        let longPrompt = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3333)

        // (1) q4 KV generation (quantizedMM path) — reference
        let q4Start = ContinuousClock.now
        let q4Result = try await container.perform { context async throws -> GenerateResult in
            let input = try await context.processor.prepare(input: .init(prompt: longPrompt))
            return try await MLXLMCommon.generate(
                input: input,
                parameters: .init(
                    maxTokens: 40, maxKVSize: 132_096, kvBits: 4,
                    temperature: 0.2, topP: 0.9,
                    repetitionPenalty: 1.05, repetitionContextSize: 64,
                    prefillStepSize: 512
                ),
                context: context
            ) { _ in .more }
        }
        let q4Tps = Double(q4Result.tokenIds.count) / max(q4Result.generateTime, 0.001)
        print("[ATTN-BENCH] q4-quantizedMM-30k: gen_tps=\(String(format: "%.1f", q4Tps))")

        // (2) fp16 KV generation (fused vector SDPA path) on the SAME context
        let fp16Start = ContinuousClock.now
        let fp16Result = try await container.perform { context async throws -> GenerateResult in
            let input = try await context.processor.prepare(input: .init(prompt: longPrompt))
            return try await MLXLMCommon.generate(
                input: input,
                parameters: .init(
                    maxTokens: 40, maxKVSize: 132_096, kvBits: nil,
                    temperature: 0.2, topP: 0.9,
                    repetitionPenalty: 1.05, repetitionContextSize: 64,
                    prefillStepSize: 512
                ),
                context: context
            ) { _ in .more }
        }
        let fp16Tps = Double(fp16Result.tokenIds.count) / max(fp16Result.generateTime, 0.001)
        print("[ATTN-BENCH] fp16-fusedSDPA-30k: gen_tps=\(String(format: "%.1f", fp16Tps))")
        _ = q4Start
        _ = fp16Start
    }

    /// Map the decode-vs-context curve: fill the KV cache to exact context
    /// sizes with synthetic filler, measure decode tps across kvBits 4/8/16.
    /// Pure decode-bandwidth curve (no prefill OOM risk beyond memory).
    func testDecodeContextCurve() async throws {
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

        // Synthetic filler with ~known density: varied realistic text.
        // ~1 token per 4 chars for this tokenizer (English prose).
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank while the autumn leaves drift slowly downstream in the cool morning air. "
        // ~0.25 tokens/char → chars per token ≈ 4
        let contexts: [Int] = [8192, 16384, 32768, 65536]
        let kvBitsOptions: [Int?] = [nil]  // fp16 is the primary memory question; add [4,8] to re-map speed

        for kvBits in kvBitsOptions {
            for ctxTarget in contexts {
                // Build filler of ~ctxTarget tokens. Reserve ~10% for safety
                // (tokenizer variance) — we fill to ~90% of target.
                let targetChars = Int(Double(ctxTarget) * 4.0 * 0.9)
                let repeats = max(1, targetChars / sentence.count)
                let filler = String(repeating: sentence, count: repeats)
                let label = kvBits.map { "q\($0)" } ?? "fp16"

                let rssBeforeMB = currentProcessRSSMB()
                let start = ContinuousClock.now
                // Sample memory DURING generation (cache is live) via the
                // per-token callback — measuring after generate() returns is
                // after teardown (cache freed).
                let memSampler = MemorySampler()
                let result = try await container.perform { context async throws -> GenerateResult in
                    let input = try await context.processor.prepare(input: .init(prompt: filler))
                    return try await MLXLMCommon.generate(
                        input: input,
                        parameters: .init(
                            maxTokens: 64, maxKVSize: 132_096, kvBits: kvBits,
                            temperature: 0.2, topP: 0.9,
                            repetitionPenalty: 1.05, repetitionContextSize: 64,
                            prefillStepSize: 512
                        ),
                        context: context
                    ) { _ in
                        memSampler.sample(active: Memory.snapshot().activeMemory, rss: currentProcessRSSMB())
                        return .more
                    }
                }
                let elapsedSec = start.duration(to: .now).components.seconds
                let actualTokens = result.promptTokenIds.count
                let genTps = Double(result.tokenIds.count) / max(result.generateTime, 0.001)
                let peakActiveMB = memSampler.peakActiveMB
                let peakRSSMB = memSampler.peakRSSMB
                print("[CURVE-MEM] \(label) ctx_actual=\(actualTokens) gen_tps=\(String(format: "%.1f", genTps)) peakActiveMB=\(peakActiveMB) peakRSSMB=\(peakRSSMB) rssBeforeMB=\(rssBeforeMB) wall_s=\(elapsedSec)")
            }
        }
    }

    /// Tracks peak MLX active + process RSS during generation.
    private final class MemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var _peakActiveMB = 0
        private var _peakRSSMB = 0
        var peakActiveMB: Int { lock.lock(); defer { lock.unlock() }; return _peakActiveMB }
        var peakRSSMB: Int { lock.lock(); defer { lock.unlock() }; return _peakRSSMB }
        func sample(active: Int, rss: Int) {
            let activeMB = active / (1024 * 1024)
            lock.lock()
            if activeMB > _peakActiveMB { _peakActiveMB = activeMB }
            if rss > _peakRSSMB { _peakRSSMB = rss }
            lock.unlock()
        }
    }
}
