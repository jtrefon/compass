import Foundation

internal struct OpenRouterChatResponse: Decodable {
    let choices: [OpenRouterChatResponseChoice]
    let usage: OpenRouterChatUsage?
}

/// Streaming chunk response from OpenRouter
internal struct OpenRouterChatResponseChunk: Decodable {
    let choices: [OpenRouterChatResponseChunkChoice]
    let usage: OpenRouterChatUsage?
}

internal struct OpenRouterChatResponseChunkChoice: Decodable {
    let delta: OpenRouterChatResponseChunkDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

internal struct OpenRouterChatResponseChunkDelta: Decodable {
    let content: String?
    let toolCalls: [OpenRouterChatResponseChunkToolCall]?
    let reasoning: String?
    let reasoningContent: String?
    /// Anthropic Claude (and some providers) stream chain-of-thought in
    /// `delta.thinking` — without this the reasoning is silently dropped.
    let thinking: String?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
        case reasoning
        case reasoningContent = "reasoning_content"
        case thinking
    }
}

internal struct OpenRouterChatResponseChunkToolCall: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: OpenRouterChatResponseChunkFunction?
}

internal struct OpenRouterChatResponseChunkFunction: Decodable {
    let name: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)

        if let argString = try? container.decode(String.self, forKey: .arguments) {
            arguments = argString
            return
        }

        if let argJSON = try? container.decode(OpenRouterDecodableJSON.self, forKey: .arguments) {
            arguments = argJSON.jsonString()
            return
        }

        arguments = nil
    }
}

internal struct OpenRouterChatUsage: Decodable {
    struct CostDetails: Decodable {
        let upstreamInferenceCost: Decimal?

        enum CodingKeys: String, CodingKey {
            case upstreamInferenceCost = "upstream_inference_cost"
        }
    }

    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheWriteTokens: Int?
    let cacheHitTokens: Int?
    let costMicrodollars: Int?
    let cost: Decimal?
    let costDetails: CostDetails?
    let provider: String?
    let isByok: Bool?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case cacheHitTokens = "cache_hit_tokens"
        case costMicrodollars = "cost_microdollars"
        case cost
        case costDetails = "cost_details"
        case provider
        case isByok = "is_byok"
    }
}

typealias OpenRouterDecodableJSON = DecodableJSON
