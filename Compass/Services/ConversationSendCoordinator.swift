import Foundation

// MARK: - SendRequest (moved from ConversationSendModels.swift)

struct SendRequest {
    let userInput: String
    let mode: AIMode
    let projectRoot: URL
    let conversationId: String
    let runId: String
    let availableTools: [AITool]
    let draftAssistantMessageId: UUID?
    let usesLocalModel: Bool
    let preservesCache: Bool

    init(
        userInput: String,
        mode: AIMode,
        projectRoot: URL,
        conversationId: String,
        runId: String,
        availableTools: [AITool],
        draftAssistantMessageId: UUID?,
        usesLocalModel: Bool = false,
        preservesCache: Bool = false
    ) {
        self.userInput = userInput
        self.mode = mode
        self.projectRoot = projectRoot
        self.conversationId = conversationId
        self.runId = runId
        self.availableTools = availableTools
        self.draftAssistantMessageId = draftAssistantMessageId
        self.usesLocalModel = usesLocalModel
        self.preservesCache = preservesCache
    }
}

// MARK: - Coordinator

@MainActor
final class ConversationSendCoordinator {
    private let historyCoordinator: ChatHistoryCoordinator
    private let aiInteractionCoordinator: AIInteractionCoordinator
    private let toolExecutionCoordinator: ToolExecutionCoordinator
    private let localModelToolLoop: LocalModelToolLoop
    var clearStreamingBuffer: (@MainActor () -> Void)?

    init(
        historyCoordinator: ChatHistoryCoordinator,
        aiInteractionCoordinator: AIInteractionCoordinator,
        toolExecutionCoordinator: ToolExecutionCoordinator
    ) {
        self.historyCoordinator = historyCoordinator
        self.aiInteractionCoordinator = aiInteractionCoordinator
        self.toolExecutionCoordinator = toolExecutionCoordinator
        self.localModelToolLoop = LocalModelToolLoop(
            history: historyCoordinator,
            aiInteractionCoordinator: aiInteractionCoordinator,
            toolExecutionCoordinator: toolExecutionCoordinator
        )
    }

    func send(_ request: SendRequest) async throws {
        await AppLogger.shared.debug(
            category: .conversation,
            message: "send.start",
            context: AppLogger.LogCallContext(metadata: [
                "conversationId": String(request.conversationId.prefix(8)),
                "mode": request.mode.rawValue,
                "classification": RequestClassifier.classify(request.userInput).rawValue
            ])
        )

        let response: AIServiceResponse
        if request.usesLocalModel {
            let localTools = LocalModelToolProvider.safeTools(from: request.availableTools)
            response = try await executeLocalModelToolLoop(request: request, localTools: localTools)
        } else {
            response = try await executeNewArchitectureFlow(request)
        }

        // Commit the assistant message to history and log it. Markup is
        // stripped at this boundary (provider-agnostic) so raw tool-call text
        // never lands in committed history; think blocks are split into the
        // reasoning field (single implementation: ReasoningSplitter).
        let committedSplit = ReasoningSplitter.apply(to: response)
        let finalContent = ToolMarkupStripper
            .assistantContent(committedSplit.content, toolCalls: response.toolCalls)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if finalContent.isEmpty {
            // A run that ends with no visible content must not leave an empty
            // bubble (and empty model context) — clean up the draft instead.
            if let draftId = request.draftAssistantMessageId {
                if historyCoordinator.getDraftMessage(id: draftId) != nil {
                    let draft = historyCoordinator.getDraftMessage(id: draftId)
                    await historyCoordinator.commitDraft(replacingWith: ChatMessage(
                        id: draftId, role: .assistant,
                        content: "The run completed without producing a visible response.",
                        timestamp: draft?.timestamp ?? Date()
                    ))
                }
            }
        } else if let draftId = request.draftAssistantMessageId {
            if let draft = historyCoordinator.getDraftMessage(id: draftId) {
                let committed = ChatMessage(
                    id: draft.id, role: .assistant, content: finalContent,
                    timestamp: draft.timestamp,
                    context: ChatMessageContentContext(reasoning: committedSplit.reasoning)
                )
                await historyCoordinator.commitDraft(replacingWith: committed)
            }
        } else {
            let msg = ChatMessage(role: .assistant, content: finalContent,
                context: ChatMessageContentContext(reasoning: committedSplit.reasoning))
            await historyCoordinator.append(msg)
        }

        // Log assistant message for telemetry
        await AppLogger.shared.info(
            category: .conversation,
            message: "chat.assistant_message",
            context: AppLogger.LogCallContext(metadata: [
                "conversationId": request.conversationId,
                "contentLength": finalContent.count,
                "classification": RequestClassifier.classify(request.userInput).rawValue
            ])
        )
        await ConversationLogStore.shared.append(
            conversationId: request.conversationId,
            type: "chat.assistant_message",
            data: ["content": finalContent]
        )

        await AppLogger.shared.debug(
            category: .conversation,
            message: "send.complete",
            context: AppLogger.LogCallContext(metadata: [
                "classification": RequestClassifier.classify(request.userInput).rawValue
            ])
        )
    }

    // MARK: - Agent Loop Flow

    private func executeNewArchitectureFlow(_ request: SendRequest) async throws -> AIServiceResponse {
        await OrchestrationRunStore.shared.setProjectRoot(request.projectRoot)

        let classification = RequestClassifier.classify(request.userInput)

        let loop = AgentLoop(
            aiCoordinator: aiInteractionCoordinator,
            historyCoordinator: historyCoordinator,
            toolExecutor: toolExecutionCoordinator,
            projectRoot: request.projectRoot,
            request: request,
            classification: classification
        )
        return try await loop.run()
    }

    // MARK: - Local Model Loop

    private func executeLocalModelToolLoop(
        request: SendRequest,
        localTools: [AITool]
    ) async throws -> AIServiceResponse {
        try await localModelToolLoop.execute(
            request: request,
            configuration: .default(
                mode: request.mode,
                projectRoot: request.projectRoot,
                conversationId: request.conversationId,
                runId: request.runId
            ),
            tools: localTools
        )
    }
}