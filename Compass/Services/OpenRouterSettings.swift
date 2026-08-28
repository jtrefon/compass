import Foundation

enum ToolPromptMode: String, Equatable {
    case fullStatic
    case concise
}

enum ReasoningMode: String, CaseIterable, Equatable {
    case none
    case model
    case agent
    case modelAndAgent

    var includesAgentReasoning: Bool {
        switch self {
        case .agent, .modelAndAgent:
            return true
        case .none, .model:
            return false
        }
    }

    var includesModelReasoning: Bool {
        switch self {
        case .model, .modelAndAgent:
            return true
        case .none, .agent:
            return false
        }
    }

    var modelReasoningPromptKey: String {
        includesModelReasoning
            ? "ConversationFlow/Corrections/model_reasoning_enabled"
            : "ConversationFlow/Corrections/model_reasoning_disabled"
    }
}

enum ReasoningIntensity: String, CaseIterable, Equatable {
    case min
    case med
    case max

    static var `default`: ReasoningIntensity { .max }

    static var current: ReasoningIntensity {
        ReasoningIntensity(
            rawValue: AppRuntimeEnvironment.userDefaults.string(forKey: LocalModelSettingsKeys.reasoningIntensity) ?? ""
        ) ?? .default
    }

    var systemPromptDirective: String {
        switch self {
        case .min:
            return "Reasoning intensity: LOW. Keep reasoning extremely brief \u{2014} at most one short sentence."
        case .med:
            return "Reasoning intensity: MEDIUM. Keep reasoning compact and focused."
        case .max:
            return "Reasoning intensity: HIGH. Reason thoroughly, consider alternatives, and think step by step before responding."
        }
    }

    var apiEffortValue: String {
        switch self {
        case .min: return "low"
        case .med: return "medium"
        case .max: return "high"
        }
    }
}

struct OpenRouterSettings: Equatable {
    var apiKey: String
    var model: String
    var baseURL: String
    var systemPrompt: String
    var reasoningMode: ReasoningMode
    var toolPromptMode: ToolPromptMode
    var contextOverride: Int

    static let empty = OpenRouterSettings(
        apiKey: "",
        model: "",
        baseURL: "https://openrouter.ai/api/v1",
        systemPrompt: "",
        reasoningMode: .modelAndAgent,
        toolPromptMode: .concise,
        contextOverride: 0
    )
}
