import Foundation

public enum AIRequestStage: String, Codable, Sendable {
    case warmup
    case initial_response
    case tool_loop
    case final_response
    case qa_tool_output_review
    case qa_quality_review
    case other

    var reasoningPromptKey: String {
        switch self {
        case .tool_loop:
            return "ConversationFlow/Corrections/reasoning_optional_tool_loop"
        default:
            return "ConversationFlow/Corrections/reasoning_optional_general"
        }
    }

    static func reasoningPromptKey(for stage: AIRequestStage?) -> String {
        stage?.reasoningPromptKey ?? AIRequestStage.other.reasoningPromptKey
    }

    // Stage-independent on purpose: the system prompt must be byte-identical
    // across every request stage so the provider's prefix cache stays warm.
    // Varying this by stage was the primary cause of cache invalidation
    // (and the 60s timeouts) — see Documentation/provider-context-caching-research.md.
    static func reasoningPromptKeyIfNeeded(
        reasoningMode: ReasoningMode,
        mode: AIMode?,
        stage: AIRequestStage?
    ) -> String? {
        guard reasoningMode.includesAgentReasoning, mode == .agent || mode == .coder else { return nil }
        return AIRequestStage.other.reasoningPromptKey
    }

    static func reasoningPromptIfNeeded(
        reasoningMode: ReasoningMode,
        mode: AIMode?,
        stage: AIRequestStage?,
        projectRoot: URL?
    ) throws -> String? {
        guard let promptKey = reasoningPromptKeyIfNeeded(
            reasoningMode: reasoningMode,
            mode: mode,
            stage: stage
        ) else {
            return nil
        }
        return try PromptRepository.shared.prompt(key: promptKey, projectRoot: projectRoot)
    }
}

public struct AIServiceHistoryRequest: Sendable {
    public let messages: [ChatMessage]
    public let mediaAttachments: [ChatMessageMediaAttachment]
    public let context: String?
    public let tools: [AITool]?
    public let mode: AIMode?
    public let projectRoot: URL?
    public let runId: String?
    public let stage: AIRequestStage?
    public let conversationId: String?

    public init(
        messages: [ChatMessage],
        mediaAttachments: [ChatMessageMediaAttachment] = [],
        context: String? = nil,
        tools: [AITool]?,
        mode: AIMode?,
        projectRoot: URL?,
        runId: String? = nil,
        stage: AIRequestStage? = nil,
        conversationId: String? = nil
    ) {
        self.messages = messages
        self.mediaAttachments = mediaAttachments
        self.context = context
        self.tools = tools
        self.mode = mode
        self.projectRoot = projectRoot
        self.runId = runId
        self.stage = stage
        self.conversationId = conversationId
    }
}
