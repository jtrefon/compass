import Foundation

internal struct OpenRouterChatRequest: Encodable {
    struct Reasoning: Encodable {
        let enabled: Bool
        let effort: String?
        let exclude: Bool

        init(configuration: OpenRouterAIService.NativeReasoningConfiguration) {
            self.enabled = configuration.enabled
            self.effort = configuration.effort
            self.exclude = configuration.exclude
        }
    }

    let model: String
    let messages: [OpenRouterChatMessage]
    let maxTokens: Int?
    let temperature: Double?
    let tools: [[String: Any]]?
    let toolChoice: String?
    let parallelToolCalls: Bool?
    let reasoning: Reasoning?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case reasoning
        case stream
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        if let maxTokens {
            try container.encode(maxTokens, forKey: .maxTokens)
        }
        if let temperature {
            try container.encode(temperature, forKey: .temperature)
        }
        if let tools = tools {
            // Sort keys for deterministic serialization (KV cache stability)
            let sortedTools = tools.map { dict in
                dict.keys.sorted().reduce(into: [String: Any]()) { result, key in
                    result[key] = dict[key]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: sortedTools, options: [.sortedKeys])
            let json = try JSONSerialization.jsonObject(with: data)
            try container.encode(AnyCodable(json), forKey: .tools)
        }

        if let toolChoice, !toolChoice.isEmpty {
            try container.encode(toolChoice, forKey: .toolChoice)
        }

        if let parallelToolCalls {
            try container.encode(parallelToolCalls, forKey: .parallelToolCalls)
        }

        if let reasoning {
            try container.encode(reasoning, forKey: .reasoning)
        }

        // Only encode stream if it's true (to avoid unnecessary bytes in request)
        if stream {
            try container.encode(true, forKey: .stream)
        }
    }
}
