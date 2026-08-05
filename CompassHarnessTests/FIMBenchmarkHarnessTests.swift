import XCTest
import Darwin
@testable import Compass

/// FIM benchmark harness — local model only, never runs in CI (harness suites
/// are manual via `./run.sh harness`). Requires the fixed FIM model
/// (Qwen2.5-Coder-1.5B-Instruct-4bit) to be installed; otherwise the suite skips.
///
/// Tuning knobs (env vars, all optional):
///   COMPASS_FIM_TEMPERATURE            default 0.1
///   COMPASS_FIM_TOP_P                  default 0.9
///   COMPASS_FIM_REPETITION_PENALTY     default 1.1
///   COMPASS_FIM_MAX_TOKENS             default 64
///   COMPASS_FIM_CONTEXT_CHARS_PER_TOKEN default 2.0 (prefix builder only)
///   COMPASS_FIM_MAX_SUGGESTIONS        default 5 (capacity test)
///   COMPASS_FIM_REPEAT_ROUNDS          default 3 (latency median + determinism rounds)
///
/// Token counts are ESTIMATED at 3.5 chars/token (Qwen2.5-Coder BPE) — the
/// service does not expose token counts; treat tps as approximate.
final class FIMBenchmarkHarnessTests: XCTestCase {
    private static let modelContextTokens = 4096  // hardcoded in FIMInferenceService
    private static let charsPerToken = 3.5        // BPE estimate for output counting

    private func env(_ key: String, _ fallback: Double) -> Double {
        guard let raw = envString(key), let v = Double(raw) else {
            return fallback
        }
        return v
    }

    private func env(_ key: String, _ fallback: Int) -> Int {
        guard let raw = envString(key), let v = Int(raw) else {
            return fallback
        }
        return v
    }

    /// xcodebuild does NOT propagate env vars into the app-hosted test
    /// process. Resolution order:
    ///   1. direct env (non-hosted runs)
    ///   2. TEST_RUNNER_ENV_<KEY> (xcodebuild passthrough)
    ///   3. fim-bench.conf in the test profile dir (run.sh writes it; the
    ///      profile path is found via the compass-test-profile-path marker
    ///      file — same mechanism as AppLaunchContext).
    private func envString(_ key: String) -> String? {
        let processEnv = ProcessInfo.processInfo.environment
        if let direct = processEnv[key], !direct.isEmpty { return direct }
        if let prefixed = processEnv["TEST_RUNNER_ENV_\(key)"], !prefixed.isEmpty { return prefixed }
        guard let confURL = fimBenchConfURL(),
              let conf = try? String(contentsOf: confURL, encoding: .utf8) else {
            return nil
        }
        for line in conf.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == Substring(key) {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
    }

    private func fimBenchConfURL() -> URL? {
        guard let marker = try? String(contentsOf:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/compass-test-profile-path"),
            encoding: .utf8),
            !marker.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: marker.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("fim-bench.conf")
    }

    private func makeService() async throws -> FIMInferenceService {
        let model = LocalModelCatalog.fimModel
        guard LocalModelFileStore.isModelInstalled(model) else {
            throw XCTSkip("FIM model not installed (\(model.id)) — run the app's model downloader first")
        }
        return try await FIMInferenceService(modelId: model.id)
    }

    private func samplingConfig() -> (temperature: Float, topP: Float, repetitionPenalty: Float, maxTokens: Int) {
        // Defaults must mirror production FIMInferenceService defaults so an
        // env-free run benchmarks exactly what the app ships. The output
        // budget stays small: the product renders only the first line.
        (Float(env("COMPASS_FIM_TEMPERATURE", 0.1)),
         Float(env("COMPASS_FIM_TOP_P", 0.9)),
         Float(env("COMPASS_FIM_REPETITION_PENALTY", 1.1)),
         env("COMPASS_FIM_MAX_TOKENS", 64))
    }

    // MARK: - Corpus sanity (no leaks, structurally valid fixtures)

    func testFIMCorpusSanity() {
        let samples = FIMBenchmarkFixtures.samples
        XCTAssertFalse(samples.isEmpty, "corpus must not be empty")
        var seen = Set<String>()
        for sample in samples {
            XCTAssertFalse(sample.prefix.isEmpty, "empty prefix: \(sample.language)/\(sample.label)")
            XCTAssertFalse(sample.expected.isEmpty, "empty expected: \(sample.language)/\(sample.label)")
            let key = "\(sample.language)|\(sample.label)"
            XCTAssertTrue(seen.insert(key).inserted, "duplicate site \(key)")
            // Leak check: the answer line must not already appear as a full
            // line in the prompt (substring matches on short identifiers like
            // `count` are legitimate context and are not leaks).
            let expectedLine = sample.expected.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixLines = Set(sample.prefix.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            let suffixLines = Set(sample.suffix.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            XCTAssertFalse(prefixLines.contains(expectedLine),
                           "leaked expected line in prefix: \(sample.language)/\(sample.label)")
            XCTAssertFalse(suffixLines.contains(expectedLine),
                           "leaked expected line in suffix: \(sample.language)/\(sample.label)")
            // Structural validity: prefix + expected + suffix must be brace-balanced
            // for C-family fixtures.
            if FIMBenchmarkFixtures.braceLanguages.contains(sample.language) {
                XCTAssertEqual(braceDepth(sample.prefix + "\n" + sample.expected + "\n" + sample.suffix), 0,
                               "unbalanced fixture: \(sample.language)/\(sample.label)")
            }
        }
        Swift.print("[FIM-BENCH] corpus sanity OK: \(samples.count) sites, \(Set(samples.map(\.language)).count) languages, 0 leaks, 0 unbalanced fixtures")
    }

    // MARK: - Determinism (same input, 3 generations — output stability)

    func testFIMRepeatability() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let rounds = env("COMPASS_FIM_REPEAT_ROUNDS", 3)

        let probes = [
            FIMBenchmarkFixtures.samples.first { $0.language == "C" }!,
            FIMBenchmarkFixtures.samples.first { $0.language == "Swift" }!,
            FIMBenchmarkFixtures.samples.first { $0.language == "Perl" }!,
            FIMBenchmarkFixtures.samples.first { $0.language == "CSS" }!,
        ]
        _ = await measure(service, prefix: syntheticCode(chars: 800), suffix: "    }\n}\n", cfg: cfg, label: "repeat-warmup")

        Swift.print("[FIM-BENCH] repeatability: \(rounds) rounds × 4 probes @ temp=\(cfg.temperature)")
        for probe in probes {
            var outputs: [String] = []
            for _ in 0..<rounds {
                let run = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: cfg, label: probe.label)
                outputs.append(run.output)
            }
            let identical = outputs.dropFirst().allSatisfy { $0 == outputs[0] }
            var pairSims: [Double] = []
            for i in 0..<outputs.count {
                for j in (i + 1)..<outputs.count {
                    pairSims.append(1.0 - Double(levenshtein(outputs[i], outputs[j])) / Double(max(outputs[0].count, 1)))
                }
            }
            let avgSim = pairSims.reduce(0, +) / Double(max(pairSims.count, 1))
            Swift.print("[FIM-BENCH]   \(probe.language.padding(toLength: 10, withPad: " ", startingAt: 0)) identical=\(identical) pairSim=\(String(format: "%.3f", avgSim)) outLen=\(outputs[0].count)")
        }
    }

    // MARK: - Latency vs file size (input context 30/60/90% of 4096-token window)

    /// The product premise: FIM output is a SINGLE LINE (the renderer clamps
    /// at the first newline — CodeEditorTextView.firstLine). Input context is
    /// what grows with file size. This test measures the time-to-suggestion
    /// for small/mid/large files with a single-line output budget, and how
    /// often the model emits multi-line output (which the renderer must cut).
    func testFIMLatencyVsFileSize() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let charsPerToken = env("COMPASS_FIM_CONTEXT_CHARS_PER_TOKEN", 2.0)
        let rounds = env("COMPASS_FIM_REPEAT_ROUNDS", 3)
        let suffix = "    }\n    return total\n}\n"

        Swift.print("[FIM-BENCH] file sizes: input at 30/60/90% of \(Self.modelContextTokens)t window, single-line output budget maxTokens=\(cfg.maxTokens) temp=\(cfg.temperature) topP=\(cfg.topP)")

        let warm = await measure(service, prefix: syntheticCode(chars: 800), suffix: suffix, cfg: cfg, label: "warmup/cold-load")
        Swift.print(String(format: "[FIM-BENCH] COLD LOAD (includes model load) total=%.0fms ttft=%.0fms rssBefore=%dMB rssAfterLoad=%dMB",
                           warm.totalMs, warm.ttftMs, warm.rssBeforeMB, warm.rssAfterMB))

        let sizes = [(label: "small-file", fraction: 0.30), (label: "mid-file", fraction: 0.60), (label: "large-file", fraction: 0.90)]
        for size in sizes {
            let prefix = syntheticCode(chars: Int(Double(Self.modelContextTokens) * charsPerToken * size.fraction))
            var runs: [MeasuredRun] = []
            for round in 0..<rounds {
                runs.append(await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "\(size.label)-\(round)"))
            }
            let medTtft = runs.map(\.ttftMs).sorted()[runs.count / 2]
            let medTotal = runs.map(\.totalMs).sorted()[runs.count / 2]
            let medOut = runs.map(\.outputChars).sorted()[runs.count / 2]
            let multiLine = runs.filter(\.containsNewline).count
            let capped = runs.filter(\.capped).count
            let firstLineChars = runs.map { run in
                String(run.output.split(separator: "\n").first ?? "").count
            }.sorted()[runs.count / 2]
            let sizeLabel = pad(size.label, 11)
            Swift.print(String(format: "[FIM-BENCH]   %@ ttft=%6.0fms total=%6.0fms out=%4dch firstLine=%3dch multiline=%d/%d capped=%d/%d",
                               sizeLabel, medTtft, medTotal, medOut, firstLineChars,
                               multiLine, runs.count, capped, runs.count))
        }
    }

    // MARK: - Dropdown capacity (N suggestions per file size)

    /// Product question: can we show a dropdown of N suggestions? Output is
    /// always a single line per suggestion; N suggestions = N sequential
    /// single-line generations. Budget framing: suggestion visible within 2s
    /// of the typing pause.
    func testFIMMultipleSuggestionCapacity() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let maxSuggestions = env("COMPASS_FIM_MAX_SUGGESTIONS", 5)
        let charsPerToken = env("COMPASS_FIM_CONTEXT_CHARS_PER_TOKEN", 2.0)
        let suffix = "    }\n    return total\n}\n"

        _ = await measure(service, prefix: syntheticCode(chars: 800), suffix: suffix, cfg: cfg, label: "capacity-warmup")

        let sizes = [(label: "small", fraction: 0.30), (label: "mid", fraction: 0.60), (label: "large", fraction: 0.90)]
        for size in sizes {
            let prefix = syntheticCode(chars: Int(Double(Self.modelContextTokens) * charsPerToken * size.fraction))
            Swift.print("[FIM-BENCH] capacity @\(size.label)-file (\(Int(size.fraction * 100))% context): \(maxSuggestions) sequential single-line suggestions")
            var cumulativeMs = 0.0
            for i in 1...maxSuggestions {
                let result = await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "\(size.label)-sug-\(i)")
                cumulativeMs += result.totalMs
                Swift.print(String(format: "[FIM-BENCH]   #%d total=%6.0fms ttft=%6.0fms (cumulative %7.0fms)",
                                   i, result.totalMs, result.ttftMs, cumulativeMs))
            }
        }
    }

    // MARK: - Language quality matrix

    func testFIMLanguageQualityMatrix() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()

        _ = await measure(service, prefix: syntheticCode(chars: 800), suffix: "    }\n}\n", cfg: cfg, label: "matrix-warmup")

        let samples = FIMBenchmarkFixtures.samples
        let languages = Set(samples.map(\.language))
        Swift.print("[FIM-BENCH] language matrix: \(samples.count) sites across \(languages.count) languages")

        var perLanguage: [String: [SiteScore]] = [:]

        for sample in samples {
            let run = await measure(service, prefix: sample.prefix, suffix: sample.suffix, cfg: cfg, label: sample.label)
            let score = score(sample: sample, run: run)
            perLanguage[sample.language, default: []].append(score)
            if score.exact || score.lines || score.firstToken {
                Swift.print("[FIM-BENCH]   \(sample.language)/\(sample.label) \(score.exact ? "HIT" : score.lines ? "LINES" : "near") exact=\(score.exact) lines=\(score.lines) firstTok=\(score.firstToken) sim=\(String(format: "%.2f", score.similarity)) capped=\(score.capped)")
            }
        }

        Swift.print("[FIM-BENCH] --- per-language summary (exact = first-line exact, lines = all expected lines in order, capped = hit maxTokens) ---")
        Swift.print("[FIM-BENCH] \(pad("lang", 10)) \(pad("n", 4)) \(pad("exact", 5)) \(pad("lines", 5)) \(pad("fTok", 4)) \(pad("sim", 6)) \(pad("brOk", 4)) \(pad("cap", 3)) \(pad("ttft", 7))")
        var totals = [0, 0, 0, 0]
        var simSum = 0.0, ttftSum = 0.0, nTotal = 0
        for language in perLanguage.keys.sorted() {
            let stats = perLanguage[language]!
            let exact = stats.filter { $0.exact }.count
            let lines = stats.filter { $0.lines }.count
            let firstTok = stats.filter { $0.firstToken }.count
            let braces = stats.filter { $0.bracesOk }.count
            let capped = stats.filter { $0.capped }.count
            let sim = stats.map { $0.similarity }.reduce(0, +) / Double(stats.count)
            let ttft = stats.map { $0.ttftMs }.reduce(0, +) / Double(stats.count)
            totals[0] += exact; totals[1] += lines; totals[2] += firstTok; totals[3] += capped
            simSum += sim; ttftSum += ttft; nTotal += stats.count
            Swift.print("[FIM-BENCH] \(pad(language, 10)) \(pad("\(stats.count)", 4)) \(pad("\(exact)", 5)) \(pad("\(lines)", 5)) \(pad("\(firstTok)", 4)) \(pad(String(format: "%.3f", sim), 6)) \(pad("\(braces)/\(stats.count)", 4)) \(pad("\(capped)", 3)) \(pad(String(format: "%.0f", ttft), 7))")
        }
        Swift.print("[FIM-BENCH] \(pad("TOTAL", 10)) \(pad("\(nTotal)", 4)) \(pad("\(totals[0])", 5)) \(pad("\(totals[1])", 5)) \(pad("\(totals[2])", 4)) \(pad(String(format: "%.3f", simSum / Double(max(nTotal, 1))), 6)) \(pad("-", 4)) \(pad("\(totals[3])", 3)) \(pad(String(format: "%.0f", ttftSum / Double(max(nTotal, 1))), 7))")
    }

    // MARK: - Context-window sweep (the latency curve + incremental-prefill proxy)

    /// Maps TTFT vs input window size — answers the +N/-N strategy questions:
    /// how fast is a suggestion at a 10-line window vs a full large file?
    /// The TTFT slope between sizes ≈ the per-character incremental prefill
    /// cost (what per-keystroke prediction would cost if the KV cache were
    /// reused across calls).
    func testFIMContextWindowSweep() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let rounds = env("COMPASS_FIM_REPEAT_ROUNDS", 3)
        let suffix = syntheticSuffix(chars: 300)

        _ = await measure(service, prefix: syntheticCode(chars: 800), suffix: suffix, cfg: cfg, label: "sweep-warmup")

        let sizes: [(label: String, chars: Int)] = [
            ("10-10-lines", 400),       // ≈ 10 lines before + 300ch after
            ("20-20-lines", 800),
            ("prod-window", 1500),      // current production assembler window
            ("small-30%", 2458),
            ("mid-60%", 4915),
            ("large-90%", 7373),
        ]
        Swift.print("[FIM-BENCH] context window sweep (suffix=300ch, median-of-\(rounds), maxTokens=\(cfg.maxTokens))")
        Swift.print("[FIM-BENCH] \(pad("window", 12)) \(pad("ttft", 7)) \(pad("total", 7)) \(pad("firstLine", 10))")
        var prevTtft: Double?
        var prevChars = 0
        for size in sizes {
            let prefix = syntheticCode(chars: size.chars)
            var runs: [MeasuredRun] = []
            for round in 0..<rounds {
                runs.append(await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "\(size.label)-\(round)"))
            }
            let medTtft = runs.map(\.ttftMs).sorted()[runs.count / 2]
            let medTotal = runs.map(\.totalMs).sorted()[runs.count / 2]
            let firstLine = runs.map { run in String(run.output.split(separator: "\n").first ?? "").count }.sorted()[runs.count / 2]
            var msPer100ch = ""
            if let prev = prevTtft {
                let delta = medTtft - prev
                let stepChars = size.chars - prevChars
                msPer100ch = String(format: "%.0f", delta / Double(stepChars) * 100)
            }
            Swift.print("[FIM-BENCH] \(pad(size.label, 12)) \(pad(String(format: "%.0f", medTtft), 7)) \(pad(String(format: "%.0f", medTotal), 7)) \(pad("\(firstLine)ch", 10)) \(pad(msPer100ch, 7))")
            prevTtft = medTtft
            prevChars = size.chars
        }
    }

    // MARK: - Quality vs input window size (does more context change quality?)

    /// Same 49-site corpus, run with padded surrounding context (narrow,
    /// 1500 chars, 4000 chars). Validates the narrow-window strategy: if
    /// quality is flat, +10/-10 costs nothing and buys 4-9x latency.
    func testFIMQualityVsWindowSize() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let paddings: [(label: String, chars: Int)] = [("narrow", 0), ("mid-1500", 1500), ("wide-4000", 4000)]

        _ = await measure(service, prefix: syntheticCode(chars: 800), suffix: "    }\n}\n", cfg: cfg, label: "ablation-warmup")

        for padding in paddings {
            var exact = 0, lines = 0, firstTok = 0, n = 0
            for sample in FIMBenchmarkFixtures.samples {
                let prefix = paddedContext(sample.prefix, to: padding.chars, before: true)
                let suffix = paddedContext(sample.suffix, to: padding.chars, before: false)
                let run = await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "\(padding.label)-\(sample.label)")
                let score = score(sample: sample, run: run)
                if score.exact { exact += 1 }
                if score.lines { lines += 1 }
                if score.firstToken { firstTok += 1 }
                n += 1
            }
            Swift.print("[FIM-BENCH] quality @\(padding.label): exact=\(exact)/\(n) lines=\(lines)/\(n) firstTok=\(firstTok)/\(n)")
        }
    }

    /// Pad a context with balanced synthetic code (repeating the sample's own
    /// text would unbalance braces and corrupt the fixture).
    private func paddedContext(_ text: String, to chars: Int, before: Bool) -> String {
        guard chars > 0 else { return text }
        let filler = before
            ? syntheticCode(chars: chars)
            : syntheticSuffix(chars: chars)
        return before ? filler + "\n" + text : text + "\n" + filler
    }

    // MARK: - Per-keystroke cost with KV reuse (the adaptive-budget enabler)

    /// Simulates typing at a cursor in a mid-size file. First call = full
    /// prefill; each keystroke appends a char to the prefix and drops it from
    /// the suffix head — exactly what FIM KV-cache reuse trims to a delta.
    /// Measures: initial prefill, then per-keystroke cost at the production
    /// budget (64) and at an adaptive/small budget (4 tokens).
    func testFIMPerKeystrokeCostWithKVReuse() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let suffixTail = "ue, scale: 2.0)\n    return result\n}\n" + syntheticSuffix(chars: 300)

        // Cursor at "computeItem(va|ue, scale: 2.0)" inside a mid-size file.
        var prefix = syntheticCode(chars: 2000) + "\n    let result = computeItem(va"
        var suffix = suffixTail
        let typed = "lue, scale: 2.0)"

        let full = await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "initial-prefill")
        Swift.print(String(format: "[FIM-BENCH] KV initial prefill (mid-size file): total=%.0fms ttft=%.0fms", full.totalMs, full.ttftMs))

        Swift.print("[FIM-BENCH] per-keystroke cost @maxTokens=64 (production budget):")
        var cumulative = 0.0
        for (i, ch) in typed.enumerated() {
            prefix.append(ch)
            if suffix.hasPrefix(String(ch)) { suffix.removeFirst() }
            let run = await measure(service, prefix: prefix, suffix: suffix, cfg: cfg, label: "kv-keystroke-\(i + 1)")
            cumulative += run.totalMs
            Swift.print(String(format: "[FIM-BENCH]   key %2d total=%6.0fms ttft=%6.0fms (avg %6.0fms)", i + 1, run.totalMs, run.ttftMs, cumulative / Double(i + 1)))
        }

        Swift.print("[FIM-BENCH] per-keystroke cost @maxTokens=4 (adaptive budget):")
        var adaptiveCfg = cfg
        adaptiveCfg.maxTokens = 4
        var cumulativeSmall = 0.0
        for (i, ch) in typed.enumerated() {
            prefix.append(ch)
            if suffix.hasPrefix(String(ch)) { suffix.removeFirst() }
            let run = await measure(service, prefix: prefix, suffix: suffix, cfg: adaptiveCfg, label: "adaptive-keystroke-\(i + 1)")
            cumulativeSmall += run.totalMs
            Swift.print(String(format: "[FIM-BENCH]   key %2d total=%6.0fms ttft=%6.0fms (avg %6.0fms)", i + 1, run.totalMs, run.ttftMs, cumulativeSmall / Double(i + 1)))
        }
    }

    // MARK: - KV reuse transparency (fresh vs reused, same prompt)

    /// Does reusing the KV cache change the output for the same prompt?
    /// Compares: (A) fresh prefill w/ repPen, (B) reused cache w/ repPen,
    /// (C) fresh prefill w/o repPen. If B == A, reuse is transparent.
    func testFIMKVReuseTransparency() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()

        let warmupPrefix = syntheticCode(chars: 2000) + "\n    let result = computeItem(va"
        let warmupSuffix = "lue, scale: 2.0)\n    return result\n}\n"

        // Warm the cache with a prompt sharing most of its prefix.
        _ = await measure(service, prefix: warmupPrefix, suffix: warmupSuffix, cfg: cfg, label: "warmup")

        // The probe: same line continued by one char (maximal sharing).
        let probePrefix = warmupPrefix + "l"
        let probeSuffix = "ue, scale: 2.0)\n    return result\n}\n"

        // B: reused cache.
        let reused = await measure(service, prefix: probePrefix, suffix: probeSuffix, cfg: cfg, label: "reused")
        // A: fresh prefill (same prompt, cache cleared).
        await service.unload()
        _ = await measure(service, prefix: warmupPrefix, suffix: warmupSuffix, cfg: cfg, label: "rewarm")
        let fresh = await measure(service, prefix: probePrefix, suffix: probeSuffix, cfg: cfg, label: "fresh")

        let identical = fresh.output == reused.output
        let sim = 1.0 - Double(levenshtein(fresh.output, reused.output)) / Double(max(fresh.output.count, reused.output.count, 1))
        Swift.print("[FIM-BENCH] KV transparency: identical=\(identical) sim=\(String(format: "%.3f", sim)) freshLen=\(fresh.output.count) reusedLen=\(reused.output.count)")

        // C: fresh prefill without repetition penalty.
        var noRepCfg = cfg
        noRepCfg.repetitionPenalty = 1.0
        await service.unload()
        _ = await measure(service, prefix: warmupPrefix, suffix: warmupSuffix, cfg: noRepCfg, label: "rewarm-norep")
        let freshNoRep = await measure(service, prefix: probePrefix, suffix: probeSuffix, cfg: noRepCfg, label: "fresh-norep")
        let reusedNoRep: MeasuredRun
        do {
            _ = try await service.unload()
            _ = await measure(service, prefix: warmupPrefix, suffix: warmupSuffix, cfg: noRepCfg, label: "warmup-norep")
            reusedNoRep = await measure(service, prefix: probePrefix, suffix: probeSuffix, cfg: noRepCfg, label: "reused-norep")
        }
        let identicalNoRep = freshNoRep.output == reusedNoRep.output
        let simNoRep = 1.0 - Double(levenshtein(freshNoRep.output, reusedNoRep.output)) / Double(max(freshNoRep.output.count, reusedNoRep.output.count, 1))
        Swift.print("[FIM-BENCH] KV transparency (no repPen): identical=\(identicalNoRep) sim=\(String(format: "%.3f", simNoRep))")

        // Small-common-prefix case (the matrix scenario): unrelated prompts
        // sharing only the FIM special tokens.
        let smallA = FIMBenchmarkFixtures.samples.first { $0.language == "C" }!
        let smallB = FIMBenchmarkFixtures.samples.first { $0.language == "Java" }!
        await service.unload()
        _ = await measure(service, prefix: smallA.prefix, suffix: smallA.suffix, cfg: cfg, label: "warm-smallA")
        let reusedSmall = await measure(service, prefix: smallB.prefix, suffix: smallB.suffix, cfg: cfg, label: "reused-smallB")
        await service.unload()
        _ = await measure(service, prefix: smallA.prefix, suffix: smallA.suffix, cfg: cfg, label: "rewarm-smallA")
        let freshSmall = await measure(service, prefix: smallB.prefix, suffix: smallB.suffix, cfg: cfg, label: "fresh-smallB")
        let identicalSmall = freshSmall.output == reusedSmall.output
        let simSmall = 1.0 - Double(levenshtein(freshSmall.output, reusedSmall.output)) / Double(max(freshSmall.output.count, reusedSmall.output.count, 1))
        Swift.print("[FIM-BENCH] KV transparency small-common: identical=\(identicalSmall) sim=\(String(format: "%.3f", simSmall)) fresh=[\(freshSmall.output.prefix(80))] reused=[\(reusedSmall.output.prefix(80))]")

        // Output-length distribution: 4x fresh vs 4x reused (each warmed with A).
        var freshLens: [Int] = []
        var reusedLens: [Int] = []
        for _ in 0..<4 {
            await service.unload()
            _ = await measure(service, prefix: smallA.prefix, suffix: smallA.suffix, cfg: cfg, label: "rewarm-len")
            let f = await measure(service, prefix: smallB.prefix, suffix: smallB.suffix, cfg: cfg, label: "fresh-len")
            freshLens.append(f.outputChars)
            _ = await measure(service, prefix: smallA.prefix, suffix: smallA.suffix, cfg: cfg, label: "warm-len")
            let r = await measure(service, prefix: smallB.prefix, suffix: smallB.suffix, cfg: cfg, label: "reused-len")
            reusedLens.append(r.outputChars)
        }
        Swift.print("[FIM-BENCH] KV output lengths fresh=\(freshLens) reused=\(reusedLens)")
    }

    // MARK: - Variant decoding (Phase A: banned tokens + trim-back-K)

    /// Deterministic exclusion: (1) same prompt twice must be byte-identical
    /// (validates the trim-back-K decode path), (2) banning the first token
    /// must change the output, (3) the same ban twice must be identical.
    func testFIMBannedTokenDeterminism() async throws {
        let service = try await makeService()
        let cfg = samplingConfig()
        let probe = FIMBenchmarkFixtures.samples.first { $0.language == "C" }!

        let base = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: cfg, label: "base")
        let firstID = await service.lastGeneratedFirstTokenID
        let repeatRun = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: cfg, label: "same-prompt")
        let repeatID = await service.lastGeneratedFirstTokenID

        let identicalSamePrompt = base.output == repeatRun.output
        Swift.print("[FIM-BENCH] banned-token: same-prompt identical=\(identicalSamePrompt) firstToken=\(firstID ?? -1) repeated=\(repeatID ?? -1)")
        XCTAssertTrue(identicalSamePrompt, "same prompt must decode byte-identically (trim-back-K transparency)")

        guard let firstID else {
            XCTFail("no first token captured")
            return
        }

        var variantCfg = cfg
        variantCfg.temperature = 0.3
        let banned = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: variantCfg, bannedTokenIDs: [firstID], label: "banned")
        let bannedFirst = await service.lastGeneratedFirstTokenID
        let banned2 = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: variantCfg, bannedTokenIDs: [firstID], label: "banned-repeat")

        let differs = banned.output != base.output
        let deterministic = banned.output == banned2.output
        Swift.print("[FIM-BENCH] banned-token: differs=\(differs) firstToken=\(bannedFirst ?? -1) deterministic=\(deterministic)")
        XCTAssertTrue(differs, "banning the first token must change the output")
        XCTAssertTrue(deterministic, "same ban must reproduce the same output")
        XCTAssertNotEqual(bannedFirst, firstID, "banned variant must not start with the banned token")
    }

    /// Chain cost: 1 prefill + 4 banned variants with the temp ladder —
    /// the pool-of-5 economics (FIM_VariantPools_Arch.md §4).
    func testFIMVariantChainCost() async throws {
        let service = try await makeService()
        var cfg = samplingConfig()
        cfg.maxTokens = 8
        let probe = FIMBenchmarkFixtures.samples.first { $0.language == "Java" }!

        let ladder: [Float] = [0.3, 0.5, 0.5, 0.7]
        var bans: [Int] = []
        var outputs: [String] = []
        var firstTokens: [Int] = []
        var cumulative = 0.0

        let first = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: cfg, label: "variant-1")
        outputs.append(first.output)
        cumulative += first.totalMs
        if let t = await service.lastGeneratedFirstTokenID { bans.append(t) }
        Swift.print(String(format: "[FIM-BENCH] variant #1 total=%6.0fms firstTok=%d out=[%@]",
                           first.totalMs, bans.last ?? -1, String(first.output.prefix(40))))

        for (i, temp) in ladder.enumerated() {
            cfg.temperature = temp
            let run = await measure(service, prefix: probe.prefix, suffix: probe.suffix, cfg: cfg, bannedTokenIDs: bans, label: "variant-\(i + 2)")
            outputs.append(run.output)
            cumulative += run.totalMs
            let tok = await service.lastGeneratedFirstTokenID
            if let tok { firstTokens.append(tok) }
            if let tok, !bans.contains(tok) { bans.append(tok) }
            Swift.print(String(format: "[FIM-BENCH] variant #%d total=%6.0fms temp=%.1f firstTok=%d out=[%@]",
                               i + 2, run.totalMs, temp, tok ?? -1, String(run.output.prefix(40))))
        }

        let uniqueFirsts = Set(firstTokens).count
        let distinctOutputs = Set(outputs).count
        Swift.print(String(format: "[FIM-BENCH] chain: 5 variants total=%.0fms (avg %.0fms) distinctFirst=%d/%d distinctOutputs=%d/%d",
                           cumulative, cumulative / 5, uniqueFirsts, firstTokens.count, distinctOutputs, outputs.count))
    }

    /// Pool-of-5 recall vs single-shot exact-match across the whole corpus —
    /// the quality gate for the variant-pool architecture: do the banned
    /// alternatives add value beyond the single prediction?
    func testFIMVariantPoolRecall() async throws {
        let service = try await makeService()
        var cfg = samplingConfig()
        let samples = FIMBenchmarkFixtures.samples
        var singleExact = 0
        var poolRecall = 0
        var n = 0

        for sample in samples {
            var bans: [Int] = []
            var firstLines: [String] = []

            let v1 = await measure(service, prefix: sample.prefix, suffix: sample.suffix, cfg: cfg, label: "\(sample.label)-v1")
            firstLines.append(firstLine(of: v1.output))
            if let t = await service.lastGeneratedFirstTokenID { bans.append(t) }

            for temp in VariantPoolService.variantTemps {
                var vcfg = cfg
                vcfg.temperature = temp
                let run = await measure(service, prefix: sample.prefix, suffix: sample.suffix, cfg: vcfg, bannedTokenIDs: bans, label: "\(sample.label)-v\(bans.count + 1)")
                firstLines.append(firstLine(of: run.output))
                if let t = await service.lastGeneratedFirstTokenID, !bans.contains(t) { bans.append(t) }
            }

            let expectedFirst = sample.expected.split(separator: "\n").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? ""
            let gotFirsts = firstLines.map { $0.trimmingCharacters(in: .whitespaces) }
            if gotFirsts.first == expectedFirst { singleExact += 1 }
            if gotFirsts.contains(expectedFirst) { poolRecall += 1 }
            n += 1
        }

        Swift.print("[FIM-BENCH] pool recall: single=\(singleExact)/\(n) pool5=\(poolRecall)/\(n) (+\(poolRecall - singleExact))")
    }

    private func firstLine(of output: String) -> String {
        String(output.split(separator: "\n").first ?? "")
    }

    // MARK: - Metrics plumbing

    private struct MeasuredRun {
        let label: String
        let ttftMs: Double
        let totalMs: Double
        let outputChars: Int
        let output: String
        let capped: Bool
        let containsNewline: Bool
        let rssBeforeMB: Int
        let rssAfterMB: Int
    }

    private struct SiteScore {
        let exact: Bool
        let lines: Bool
        let firstToken: Bool
        let similarity: Double
        let bracesOk: Bool
        let capped: Bool
        let ttftMs: Double
        let totalMs: Double
    }

    private func measure(_ service: FIMInferenceService, prefix: String, suffix: String,
                         cfg: (temperature: Float, topP: Float, repetitionPenalty: Float, maxTokens: Int),
                         bannedTokenIDs: [Int] = [],
                         label: String) async -> MeasuredRun {
        let rssBefore = currentRSSMB()
        let start = Date()
        var firstChunkAt: Date?
        var output = ""
        do {
            let stream = await service.generateStream(
                prefix: prefix, suffix: suffix,
                maxTokens: cfg.maxTokens,
                temperature: cfg.temperature,
                topP: cfg.topP,
                repetitionPenalty: cfg.repetitionPenalty,
                bannedTokenIDs: bannedTokenIDs
            )
            for try await chunk in stream {
                if firstChunkAt == nil { firstChunkAt = Date() }
                output.append(chunk)
            }
        } catch {
            Swift.print("[FIM-BENCH]   ✗ \(label) failed: \(error)")
        }
        let ttftMs = (firstChunkAt?.timeIntervalSince(start) ?? 0) * 1000
        let totalMs = Date().timeIntervalSince(start) * 1000
        let rssAfter = currentRSSMB()
        let estTokens = Double(output.count) / Self.charsPerToken
        let capped = estTokens >= Double(cfg.maxTokens) - 2
        return MeasuredRun(label: label, ttftMs: ttftMs, totalMs: totalMs, outputChars: output.count,
                           output: output, capped: capped, containsNewline: output.contains("\n"),
                           rssBeforeMB: rssBefore, rssAfterMB: rssAfter)
    }

    private func score(sample: FIMBenchmarkSample, run: MeasuredRun) -> SiteScore {
        let generatedLines = run.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let expectedLines = sample.expected.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let expectedFirst = expectedLines.first ?? ""

        let exact = generatedLines.first == expectedFirst && !expectedFirst.isEmpty
        // Line-subsequence match: every expected line appears in order within the generation.
        var linesMatch = !expectedLines.isEmpty
        var genIdx = 0
        for expected in expectedLines {
            var found = false
            while genIdx < generatedLines.count {
                if generatedLines[genIdx] == expected { found = true; genIdx += 1; break }
                genIdx += 1
            }
            if !found { linesMatch = false; break }
        }
        let firstToken = !generatedLines.first.isNilOrEmpty && !expectedFirst.isEmpty &&
            generatedLines.first!.split(separator: " ").first == expectedFirst.split(separator: " ").first
        let similarity = 1.0 - Double(levenshtein(generatedLines.first ?? "", expectedFirst)) / Double(max(expectedFirst.count, 1))
        let bracesOk = FIMBenchmarkFixtures.braceLanguages.contains(sample.language)
            ? braceDepth(sample.prefix + "\n" + run.output + "\n" + sample.suffix) == 0
            : true
        return SiteScore(exact: exact, lines: linesMatch, firstToken: firstToken, similarity: similarity,
                         bracesOk: bracesOk, capped: run.capped, ttftMs: run.ttftMs, totalMs: run.totalMs)
    }

    private func syntheticCode(chars: Int) -> String {
        let body = """
        func computeItem(_ value: Int, scale: Double) -> Double {
            var result = Double(value) * scale
            result += Double(value % 7) * 0.25
            if result > 1000 { result = 1000 }
            return result
        }

        func processBatch(_ items: [Int], scale: Double) -> [Double] {
            var out: [Double] = []
            for item in items {
                out.append(computeItem(item, scale: scale))
            }
            return out
        }

        """
        var out = ""
        while out.count < chars {
            out += body
        }
        return String(out.prefix(chars))
    }

    private func syntheticSuffix(chars: Int) -> String {
        let body = "    }\n    return result * 2\n}\n\nfunc helper(_ x: Double) -> Double {\n    return x + 1\n}\n"
        var out = ""
        while out.count < chars {
            out += body
        }
        return String(out.prefix(chars))
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for (i, ca) in aChars.enumerated() {
            curr[0] = i + 1
            for (j, cb) in bChars.enumerated() {
                curr[j + 1] = ca == cb ? prev[j] : min(prev[j], prev[j + 1], curr[j]) + 1
            }
            (prev, curr) = (curr, prev)
        }
        return prev[bChars.count]
    }

    /// Brace depth after stripping string literals and line comments.
    /// 0 == balanced; fixtures and completions are validated against this.
    private func braceDepth(_ code: String) -> Int {
        var inString = false
        var inLineComment = false
        var stringChar: Character = "\""
        var depth = 0
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if inLineComment {
                if c == "\n" { inLineComment = false }
                i += 1
                continue
            }
            if inString {
                if c == stringChar {
                    if next == "\\" { i += 2; continue }
                    inString = false
                }
                i += 1
                continue
            }
            if c == "/" && next == "/" { inLineComment = true; i += 2; continue }
            if c == "\"" || c == "'" || c == "`" { inString = true; stringChar = c; i += 1; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            i += 1
        }
        return depth
    }

    private func currentRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    private func pad(_ s: String, _ length: Int) -> String {
        let padded = s.padding(toLength: length, withPad: " ", startingAt: 0)
        return padded.count > length ? String(padded.prefix(length)) : padded
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
