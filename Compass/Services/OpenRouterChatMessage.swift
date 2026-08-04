import Foundation

internal struct OpenRouterChatMessage: Encodable, Sendable {
    let role: String
    let content: String?
    let toolCallID: String?
    let toolCalls: [AIToolCall]?
    let reasoningContent: String?
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
        case cacheControl = "cache_control"
    }

    init(role: String, content: String? = nil, toolCallID: String? = nil, toolCalls: [AIToolCall]? = nil, reasoningContent: String? = nil, cacheControl: CacheControl? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.cacheControl = cacheControl
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

/// Anthropic/OpenRouter-style ephemeral cache breakpoint. Placed on the stable
/// system (or protected) block so the provider caches the prefix across turns.
/// See Documentation/provider-context-caching-research.md.
internal struct CacheControl: Encodable, Sendable {
    let type: String
    let ttl: String

    init(type: String = "ephemeral", ttl: String = "5m") {
        self.type = type
        self.ttl = ttl
    }
}
