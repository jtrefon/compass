import Foundation

struct LocalModelInferenceConfiguration: Sendable, Equatable, Hashable {
    let contextLength: Int
    let maxKVSize: Int
    let maxOutputTokens: Int
    let prefillStepSize: Int
    let temperature: Float
    let topP: Float
    let repetitionPenalty: Float?
    let repetitionContextSize: Int
    let kvCache4BitEnabled: Bool

    var cacheKind: String {
        maxKVSize < contextLength ? "rotating-window" : "rotating-full"
    }
}

enum LocalModelInferenceOverrides {
    /// Hard ceiling for the chat context window — derived from the model's
    /// max_position_embeddings (262144 for Qwen3.5-4B). The settings slider
    /// drives `defaultContextLength` up to here; no lower clamp remains.
    /// The env knob and the benchmark conf still override, so memory
    /// experiments remain possible without an app rebuild.
    static let maxModelContextLength = 262_144

    /// Logs a warning (non-fatal) when the resolved default is above the model's
    /// capability.
    static func logIfOverBudget(defaultContextLength: Int) {
        guard defaultContextLength > Self.maxModelContextLength else { return }
        Task {
            await AppLogger.shared.warning(
                category: .localModel,
                message: "Local model contextLength \(defaultContextLength) exceeds the model max \(Self.maxModelContextLength); clamped for the chat path (override via COMPASS_LOCAL_MODEL_CONTEXT_LENGTH)"
            )
        }
    }

    /// Resolves the inference configuration from env vars / the benchmark
    /// conf file over defaults. Env knobs are the experiment
    /// surface (run.sh forwards them to the harness process, mirroring the
    /// FIM benchmark conf pattern): direct env wins, then the conf file in
    /// the test-profile dir (harness runs cannot rely on env passthrough),
    /// then defaults.
    static func resolve(
        defaultContextLength: Int,
        defaultMaxOutputTokens: Int,
        defaultTemperature: Float,
        defaultTopP: Float,
        defaultRepetitionPenalty: Float?,
        defaultRepetitionContextSize: Int,
        defaultKVCache4BitEnabled: Bool
    ) -> LocalModelInferenceConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let conf = benchmarkConfValues(environment: environment)
        logIfOverBudget(defaultContextLength: defaultContextLength)
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? conf[key]
        }
        let envContext = parseInt(value("COMPASS_LOCAL_MODEL_CONTEXT_LENGTH"))
        let envMaxKV = parseInt(value("COMPASS_LOCAL_MODEL_MAX_KV_SIZE"))
        let envMaxOutput = parseInt(value("COMPASS_LOCAL_MODEL_MAX_OUTPUT_TOKENS"))
        let envPrefill = parseInt(value("COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE"))
        let envTemperature = parseFloat(value("COMPASS_LOCAL_MODEL_TEMPERATURE"))
        let envTopP = parseFloat(value("COMPASS_LOCAL_MODEL_TOP_P"))
        let envRepetitionPenalty = parseOptionalFloat(value("COMPASS_LOCAL_MODEL_REPETITION_PENALTY"))
        let envRepetitionContextSize = parseInt(value("COMPASS_LOCAL_MODEL_REPETITION_CONTEXT_SIZE"))

        let contextLength = clamp(
            envContext ?? defaultContextLength,
            min: 256,
            max: Self.maxModelContextLength
        )
        let maxKVSize = clamp(
            envMaxKV ?? contextLength,
            min: 256,
            max: contextLength
        )
        let maxOutputTokens = clamp(
            envMaxOutput ?? defaultMaxOutputTokens,
            min: 64,
            max: 8_192
        )
        // 4-bit KV is now permanent — ignore the old settings toggle and the
        // env var (kept for backward compat in LocalModelSelectionStore, but
        // the inference config no longer consults it). The effective value is
        // still gated by `supportsQuantizedKVCache` in LocalModelProcessAIService.
        let kvCache4BitEnabled = true
        let prefillStepSize = clamp(
            envPrefill ?? 512,
            min: 64,
            max: 4_096
        )
        let temperature = clamp(
            envTemperature ?? defaultTemperature,
            min: 0,
            max: 2
        )
        let topP = clamp(
            envTopP ?? defaultTopP,
            min: 0,
            max: 1
        )
        let repetitionPenalty = envRepetitionPenalty ?? defaultRepetitionPenalty
        let repetitionContextSize = clamp(
            envRepetitionContextSize ?? defaultRepetitionContextSize,
            min: 0,
            max: contextLength
        )
        return LocalModelInferenceConfiguration(
            contextLength: contextLength,
            maxKVSize: maxKVSize,
            maxOutputTokens: maxOutputTokens,
            prefillStepSize: prefillStepSize,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            kvCache4BitEnabled: kvCache4BitEnabled
        )
    }

    /// Reads `<test-profile-dir>/local-bench.conf` (written by run.sh from
    /// the COMPASS_LOCAL_MODEL_* env vars) — app-hosted test processes can't
    /// see the caller's env, so the conf file is the transport. The profile
    /// dir comes from the same marker file the FIM harness uses.
    private static func benchmarkConfValues(environment: [String: String]) -> [String: String] {
        let profileDir = environment["COMPASS_TEST_PROFILE_DIR"]
            ?? (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/compass-test-profile-path"),
                encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileDir, !profileDir.isEmpty,
              let conf = try? String(
                contentsOf: URL(fileURLWithPath: profileDir).appendingPathComponent("local-bench.conf"),
                encoding: .utf8
              ) else {
            return [:]
        }
        var values: [String: String] = [:]
        for line in conf.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !val.isEmpty { values[key] = val }
            }
        }
        return values
    }

    nonisolated private static func parseInt(_ rawValue: String?) -> Int? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    nonisolated private static func parseFloat(_ rawValue: String?) -> Float? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Float(trimmed)
    }

    nonisolated private static func parseOptionalFloat(_ rawValue: String?) -> Float?? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "nil" || trimmed == "none" || trimmed == "off" {
            return .some(nil)
        }
        guard let value = Float(trimmed) else { return nil }
        return .some(value)
    }

    nonisolated private static func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
        Swift.max(minimum, Swift.min(value, maximum))
    }

    nonisolated private static func clamp(_ value: Float, min minimum: Float, max maximum: Float) -> Float {
        Swift.max(minimum, Swift.min(value, maximum))
    }
}
