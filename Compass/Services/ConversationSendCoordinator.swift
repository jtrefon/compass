import Foundation

// MARK: - SendRequest (moved from ConversationSendModels.swift)

struct SendRequest {
    let userInput: String
    let mediaAttachments: [ChatMessageMediaAttachment]
    let mode: AIMode
    let projectRoot: URL
    let conversationId: String
    let runId: String
    let availableTools: [AITool]
    let draftAssistantMessageId: UUID?
    let usesLocalModel: Bool
    let modelID: String?
    let preservesCache: Bool

    init(
        userInput: String,
        mediaAttachments: [ChatMessageMediaAttachment] = [],
        mode: AIMode,
        projectRoot: URL,
        conversationId: String,
        runId: String,
        availableTools: [AITool],
        draftAssistantMessageId: UUID?,
        usesLocalModel: Bool = false,
        modelID: String? = nil,
        preservesCache: Bool = false
    ) {
        self.userInput = userInput
        self.mediaAttachments = mediaAttachments
        self.mode = mode
        self.projectRoot = projectRoot
        self.conversationId = conversationId
        self.runId = runId
        self.availableTools = availableTools
        self.draftAssistantMessageId = draftAssistantMessageId
        self.usesLocalModel = usesLocalModel
        self.modelID = modelID
        self.preservesCache = preservesCache
    }
}

// MARK: - Coordinator

@MainActor
final class ConversationSendCoordinator {
    private let historyCoordinator: ChatHistoryCoordinator
    private let aiInteractionCoordinator: AIInteractionCoordinator
    private let toolExecutionCoordinator: ToolExecutionCoordinator
    var clearStreamingBuffer: (@MainActor () -> Void)?
    var onToolStatus: (@MainActor (String) -> Void)?
    var onStatusUpdate: (@MainActor (String) -> Void)?

    init(
        historyCoordinator: ChatHistoryCoordinator,
        aiInteractionCoordinator: AIInteractionCoordinator,
        toolExecutionCoordinator: ToolExecutionCoordinator
    ) {
        self.historyCoordinator = historyCoordinator
        self.aiInteractionCoordinator = aiInteractionCoordinator
        self.toolExecutionCoordinator = toolExecutionCoordinator
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
        // never lands in committed history.
        let finalContent = ToolMarkupStripper
            .assistantContent(response.content, toolCalls: response.toolCalls)
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
                    context: ChatMessageContentContext(reasoning: response.reasoning)
                )
                await historyCoordinator.commitDraft(replacingWith: committed)
            }
        } else {
            let msg = ChatMessage(role: .assistant, content: finalContent,
                context: ChatMessageContentContext(reasoning: response.reasoning))
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
        // Pass 1: Give the model tools and let it decide. Execute any tool calls.
        let pass1 = try await aiInteractionCoordinator.sendMessageWithRetry(
            .init(messages: historyCoordinator.requestMessages, tools: localTools,
                  mode: request.mode, projectRoot: request.projectRoot,
                  runId: request.runId, stage: nil,
                  conversationId: request.conversationId, usesLocalModel: true)
        ).get()

        _ = pass1.toolCalls

        guard let toolCalls = pass1.toolCalls, !toolCalls.isEmpty else {
            return pass1  // No tools called — return as-is
        }

        // Execute tool calls and append results to history. The assistant
        // tool-call message is committed first so the request builder keeps
        // the tool results in subsequent passes (blind-loop fix).
        clearStreamingBuffer?()
        await historyCoordinator.append(
            ChatMessage(role: .assistant,
                        content: ToolMarkupStripper.assistantContent(pass1.content, toolCalls: toolCalls),
                        tool: ChatMessageToolContext(toolCalls: toolCalls))
        )
        let results = await toolExecutionCoordinator.executeToolCalls(
            toolCalls, availableTools: localTools,
            conversationId: request.conversationId
        ) { [self] progressMsg in
            if progressMsg.toolStatus == .executing {
                historyCoordinator.setLiveToolMessage(progressMsg)
            } else {
                historyCoordinator.clearLiveToolMessage(progressMsg.toolCallId ?? "")
                historyCoordinator.appendSync(progressMsg)
            }
        }
        for msg in results { await historyCoordinator.append(msg) }

        // Pass 2: Model has tool results in history — produce final response
        let pass2 = try await aiInteractionCoordinator.sendMessageWithRetry(
            .init(messages: historyCoordinator.requestMessages, tools: localTools,
                  mode: request.mode, projectRoot: request.projectRoot,
                  runId: request.runId, stage: nil,
                  conversationId: request.conversationId, usesLocalModel: true)
        ).get()
        return pass2
    }
}