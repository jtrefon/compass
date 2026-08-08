import Foundation

/// Single commit-boundary implementation: splits model think markup
/// (`<think>…</think>` and variants) out of response content into the
/// reasoning field. Providers that populate `AIServiceResponse.reasoning`
/// themselves (cloud) pass through unchanged.
enum ReasoningSplitter {
    static func apply(to response: AIServiceResponse) -> (content: String?, reasoning: String?) {
        if response.reasoning != nil {
            return (response.content, response.reasoning)
        }
        guard let content = response.content else { return (nil, nil) }
        let split = ChatPromptBuilder.splitReasoning(from: content)
        return (split.content, split.reasoning)
    }
}
