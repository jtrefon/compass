import Foundation

/// Coordinates the local model's generate → execute → repeat loop.
///
/// This is the **single production path** for local agentic tool execution.
/// The cloud path uses `AgentLoop` — never call both for the same request.
///
/// **Design rationale:**
/// - Follows the Coordinator pattern used by `ConversationSendCoordinator`
/// - Single Responsibility: owns only the loop orchestration
/// - Dependency Inversion: depends on `ConversationHistoryProviding`,
///   not the concrete `ChatHistoryCoordinator`
/// - Open/Closed: new iteration behaviors (recovery, guidance) are added
///   as methods on this class, not by modifying the loop structure
///
/// **Isolation:** `@MainActor` because all dependencies are `@MainActor`.
/// The expensive work (generation, tool execution) already runs off-main-thread
/// inside those services. This class coordinates, it does not compute.
@MainActor
final class LocalModelToolLoop {
    /// Identical-batch repeats tolerated (with corrective guidance) before
    /// the loop force-finalizes instead of burning remaining budget.
    private static let maxConsecutiveRepetitions = 2

    private let history: any ConversationHistoryProviding
    private let aiInteractionCoordinator: AIInteractionCoordinator
    private let toolExecutionCoordinator: ToolExecutionCoordinator
    private let logger: LocalModelToolLoopLogger
    private let guide: LocalModelIterationGuide

    struct Configuration {
        let maxIterations: Int
        let mode: AIMode
        let projectRoot: URL
        let conversationId: String
        let runId: String

        static func `default`(
            mode: AIMode,
            projectRoot: URL,
            conversationId: String,
            runId: String
        ) -> Configuration {
            Configuration(
                maxIterations: 8,
                mode: mode,
                projectRoot: projectRoot,
                conversationId: conversationId,
                runId: runId
            )
        }
    }

    init(
        history: any ConversationHistoryProviding,
        aiInteractionCoordinator: AIInteractionCoordinator,
        toolExecutionCoordinator: ToolExecutionCoordinator,
        logger: LocalModelToolLoopLogger = LocalModelToolLoopLogger(),
        guide: LocalModelIterationGuide = LocalModelIterationGuide()
    ) {
        self.history = history
        self.aiInteractionCoordinator = aiInteractionCoordinator
        self.toolExecutionCoordinator = toolExecutionCoordinator
        self.logger = logger
        self.guide = guide
    }

    // MARK: - Main entry point

    func execute(
        request: SendRequest,
        configuration: Configuration,
        tools: [AITool]
    ) async throws -> AIServiceResponse {
        var iteration = 0
        var allToolCalls: [AIToolCall] = []
        var previousBatch: [AIToolCall]?
        var consecutiveRepetitions = 0

        repeat {
            if iteration > 0 {
                history.clearStreamingBuffer()
            }
            let stage: AIRequestStage? = iteration > 0 ? .tool_loop : nil

            await logger.logIterationStart(
                iteration: iteration,
                stage: stage,
                messageCount: history.requestMessages.count,
                approximateTokens: 0
            )

            let response = try await aiInteractionCoordinator.sendMessageWithRetry(
                .init(messages: history.requestMessages, tools: tools,
                      mode: configuration.mode, projectRoot: configuration.projectRoot,
                      runId: configuration.runId, stage: stage,
                      conversationId: configuration.conversationId, usesLocalModel: true)
            ).get()

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                return response  // No tools called — final answer
            }

            iteration += 1
            allToolCalls.append(contentsOf: toolCalls)

            // Detect repetition against the previous batch BEFORE executing.
            // A detected identical batch increments the streak; any novel
            // call resets it.
            let repetition = previousBatch.flatMap {
                guide.detectBatchRepetition(current: toolCalls, previous: $0)
            }
            if let repetition {
                consecutiveRepetitions += 1
                await logger.logRepetition(
                    iteration: iteration,
                    currentCall: toolCalls[0],
                    previousCall: previousBatch?.last ?? toolCalls[0],
                    identicalArguments: {
                        if case .identicalCall = repetition { return true }
                        return false
                    }()
                )
            } else {
                consecutiveRepetitions = 0
            }

            guard iteration < configuration.maxIterations else {
                // Budget exhausted — force a final text answer with NO tools,
                // and tell the model WHY so the summary is grounded instead
                // of a blind cliff.
                await logger.logBudgetExhaustion(
                    iteration: iteration,
                    maxIterations: configuration.maxIterations,
                    totalToolCalls: allToolCalls.count
                )
                await history.append(ChatMessage(
                    role: .user,
                    content: guide.finalizeMessage(
                        completedIterations: iteration,
                        totalToolCalls: allToolCalls.count
                    )
                ))
                return try await finalResponse(configuration: configuration)
            }

            // Commit assistant tool-call message FIRST so the request builder
            // keeps the tool results in subsequent passes (blind-loop fix).
            let split = ReasoningSplitter.apply(to: response)
            await history.append(
                ChatMessage(role: .assistant,
                            content: ToolMarkupStripper.assistantContent(split.content, toolCalls: toolCalls),
                            context: ChatMessageContentContext(reasoning: split.reasoning),
                            tool: ChatMessageToolContext(toolCalls: toolCalls))
            )

            if consecutiveRepetitions >= Self.maxConsecutiveRepetitions {
                // Stuck loop: the model keeps re-issuing identical calls.
                // Stop executing, demand a grounded final summary instead of
                // burning the remaining budget.
                await history.append(ChatMessage(
                    role: .user,
                    content: guide.finalizeMessage(
                        completedIterations: iteration,
                        totalToolCalls: allToolCalls.count
                    )
                ))
                return try await finalResponse(configuration: configuration)
            }

            let toolResults = await toolExecutionCoordinator.executeToolCalls(
                toolCalls, availableTools: tools,
                conversationId: configuration.conversationId
            ) { [self] progressMsg in
                if progressMsg.toolStatus == .executing {
                    self.history.setLiveToolMessage(progressMsg)
                } else {
                    self.history.clearLiveToolMessage(progressMsg.toolCallId ?? "")
                    self.history.appendSync(progressMsg)
                }
            }

            await logger.logIterationComplete(
                iteration: iteration,
                toolCalls: toolCalls,
                toolResults: toolResults,
                committedCount: history.requestMessages.count,
                promptTokens: 0,
                generationTokens: 0
            )

            // Inject guidance AFTER results so the next pass sees result +
            // instruction together. Repetition gets a targeted correction;
            // fully empty results get generic continuation guidance.
            if let repetition {
                await history.append(ChatMessage(
                    role: .user,
                    content: guide.correctiveMessage(for: repetition, iteration: iteration)
                ))
            } else if toolResults.allSatisfy({ $0.content.isEmpty }) {
                let guidance = guide.continueGuidance(
                    toolCalls: toolCalls,
                    toolResults: toolResults,
                    iteration: iteration
                )
                await history.append(ChatMessage(role: .user, content: guidance))
            }

            previousBatch = toolCalls
        } while true
    }

    /// The forced no-tools send that terminates the loop.
    private func finalResponse(configuration: Configuration) async throws -> AIServiceResponse {
        try await aiInteractionCoordinator.sendMessageWithRetry(
            .init(messages: history.requestMessages, tools: [],
                  mode: configuration.mode, projectRoot: configuration.projectRoot,
                  runId: configuration.runId, stage: .tool_loop,
                  conversationId: configuration.conversationId, usesLocalModel: true)
        ).get()
    }
}
