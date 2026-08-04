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

    var label: String {
        let tempLabel = Int((temperature * 100).rounded())
        let topPLabel = Int((topP * 100).rounded())
        let repetitionLabel: String
        if let repetitionPenalty {
            repetitionLabel = "rp\(Int((repetitionPenalty * 100).rounded()))-rc\(repetitionContextSize)"
        } else {
            repetitionLabel = "rp0-rc0"
        }
        let kvLabel = kvCache4BitEnabled ? "KV4" : "noKV4"
        return "ctx\(contextLength)-kv\(maxKVSize)-out\(maxOutputTokens)-prefill\(prefillStepSize)-temp\(tempLabel)-topp\(topPLabel)-\(repetitionLabel)-\(kvLabel)"
    }
}

struct LocalModelInferenceOverrides: Sendable, Equatable {
    var contextLength: Int?
    var maxKVSize: Int?
    var maxOutputTokens: Int?
    var prefillStepSize: Int?
    var temperature: Float?
    var topP: Float?
    var repetitionPenalty: Float??
    var repetitionContextSize: Int?
    var kvCache4BitEnabled: Bool?

    static let shared = Store()

    actor Store {
        private var overrides: LocalModelInferenceOverrides?

        func set(_ overrides: LocalModelInferenceOverrides?) {
            self.overrides = overrides
        }

        func clear() {
            overrides = nil
        }

        func current() -> LocalModelInferenceOverrides? {
            overrides
        }

        func resolve(
            defaultContextLength: Int,
            defaultMaxOutputTokens: Int,
            defaultTemperature: Float,
            defaultTopP: Float,
            defaultRepetitionPenalty: Float?,
            defaultRepetitionContextSize: Int,
            defaultKVCache4BitEnabled: Bool
        ) -> LocalModelInferenceConfiguration {
            Self.resolve(
                defaultContextLength: defaultContextLength,
                defaultMaxOutputTokens: defaultMaxOutputTokens,
                defaultTemperature: defaultTemperature,
                defaultTopP: defaultTopP,
                defaultRepetitionPenalty: defaultRepetitionPenalty,
                defaultRepetitionContextSize: defaultRepetitionContextSize,
                defaultKVCache4BitEnabled: defaultKVCache4BitEnabled,
                environment: ProcessInfo.processInfo.environment,
                overrides: overrides
            )
        }

        nonisolated private static func resolve(
            defaultContextLength: Int,
            defaultMaxOutputTokens: Int,
            defaultTemperature: Float,
            defaultTopP: Float,
            defaultRepetitionPenalty: Float?,
            defaultRepetitionContextSize: Int,
            defaultKVCache4BitEnabled: Bool,
            environment: [String: String],
            overrides: LocalModelInferenceOverrides?
        ) -> LocalModelInferenceConfiguration {
            let envContext = parseInt(environment["COMPASS_LOCAL_MODEL_CONTEXT_LENGTH"])
            let envMaxKV = parseInt(environment["COMPASS_LOCAL_MODEL_MAX_KV_SIZE"])
            let envMaxOutput = parseInt(environment["COMPASS_LOCAL_MODEL_MAX_OUTPUT_TOKENS"])
            let envPrefill = parseInt(environment["COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE"])
            let envTemperature = parseFloat(environment["COMPASS_LOCAL_MODEL_TEMPERATURE"])
            let envTopP = parseFloat(environment["COMPASS_LOCAL_MODEL_TOP_P"])
            let envRepetitionPenalty = parseOptionalFloat(environment["COMPASS_LOCAL_MODEL_REPETITION_PENALTY"])
            let envRepetitionContextSize = parseInt(environment["COMPASS_LOCAL_MODEL_REPETITION_CONTEXT_SIZE"])

            let contextLength = clamp(
                overrides?.contextLength ?? envContext ?? defaultContextLength,
                min: 256,
                max: 262_144
            )
            let maxKVSize = clamp(
                overrides?.maxKVSize ?? envMaxKV ?? contextLength,
                min: 256,
                max: contextLength
            )
            let maxOutputTokens = clamp(
                overrides?.maxOutputTokens ?? envMaxOutput ?? defaultMaxOutputTokens,
                min: 64,
                max: 8_192
            )
            let kvCache4BitEnabled = overrides?.kvCache4BitEnabled ?? (environment["COMPASS_LOCAL_MODEL_KV_CACHE_4BIT"] == "0" ? false : defaultKVCache4BitEnabled)

            let prefillStepSize = clamp(
                overrides?.prefillStepSize ?? envPrefill ?? 128,
                min: 64,
                max: 4_096
            )
            let temperature = clamp(
                overrides?.temperature ?? envTemperature ?? defaultTemperature,
                min: 0,
                max: 2
            )
            let topP = clamp(
                overrides?.topP ?? envTopP ?? defaultTopP,
                min: 0,
                max: 1
            )
            let repetitionPenalty = overrides?.repetitionPenalty ?? envRepetitionPenalty ?? defaultRepetitionPenalty
            let repetitionContextSize = clamp(
                overrides?.repetitionContextSize ?? envRepetitionContextSize ?? defaultRepetitionContextSize,
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

        nonisolated private static func parseInt(_ rawValue: String?) -> Int? {
            guard let rawValue else {
                return nil
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed) else {
                return nil
            }
            return value
        }

        nonisolated private static func parseFloat(_ rawValue: String?) -> Float? {
            guard let rawValue else {
                return nil
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Float(trimmed) else {
                return nil
            }
            return value
        }

        nonisolated private static func parseOptionalFloat(_ rawValue: String?) -> Float?? {
            guard let rawValue else {
                return nil
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "nil" || trimmed == "none" || trimmed == "off" {
                return .some(nil)
            }
            guard let value = Float(trimmed) else {
                return nil
            }
            return .some(value)
        }

        nonisolated private static func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
            Swift.max(minimum, Swift.min(value, maximum))
        }

        nonisolated private static func clamp(_ value: Float, min minimum: Float, max maximum: Float) -> Float {
            Swift.max(minimum, Swift.min(value, maximum))
        }
    }
}
