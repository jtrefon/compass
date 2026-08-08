import Foundation

/// The flattened agentic loop — replaces the orchestration graph's node
/// machine (fast/review/build topologies) with a single phase-driven loop.
/// Every phase below is a direct port of a former graph node; semantics are
/// preserved one-to-one:
///
///   fast_path     → FastPathNode      (single no-tools call)
///   researcher    → ResearcherNode    (read-only exploration loop w/ budget)
///   analyst       → AnalystNode       (read-only single call)
///   architect     → ArchitectNode     (read-only single call)
///   pm            → ProjectManagerNode (plan-driven leaf counter, no LLM)
///   leaf_executor → LeafExecutorNode  (full-tools call + error retry)
///   leaf_review   → LeafReviewNode    (no-tools verdict call + rework)
///   final_response→ FinalResponseNode (pass-through or summary)
///
/// Runner-level behavior (OrchestrationGraphRunner) is also preserved:
/// transition budget, P1 empty-response-after-work recovery, P6 graceful
/// finalize, and per-transition snapshots to `.ide/orchestration/runs/`.
@MainActor
struct AgentLoop {
    private let aiCoordinator: AIInteractionCoordinator
    private let historyCoordinator: ChatHistoryCoordinator
    private let toolExecutor: ToolExecutionCoordinator
    private let projectRoot: URL
    private let request: SendRequest
    private let classification: RequestComplexity

    static let maxTransitions = 128
    static let maxEmptyRecoveries = 2
    static let leafToolErrorRetryCap = 2
    static let leafReworkCap = 2

    init(
        aiCoordinator: AIInteractionCoordinator,
        historyCoordinator: ChatHistoryCoordinator,
        toolExecutor: ToolExecutionCoordinator,
        projectRoot: URL,
        request: SendRequest,
        classification: RequestComplexity
    ) {
        self.aiCoordinator = aiCoordinator
        self.historyCoordinator = historyCoordinator
        self.toolExecutor = toolExecutor
        self.projectRoot = projectRoot
        self.request = request
        self.classification = classification
    }

    /// Run one send to completion. The final assistant content is returned
    /// to the caller; everything else is committed to history as it happens.
    func run() async throws -> AIServiceResponse {
        var phase = startPhase
        var visitCount = 0
        var planItemIndex = 0
        var leafToolErrorRetryCount = 0
        var leafReworkCount = 0
        var emptyRecoveryCount = 0
        var taskPlan: TaskPlan?
        var response: AIServiceResponse?
        var transitionCount = 0

        while transitionCount < Self.maxTransitions {
            transitionCount += 1
            let committedAtTurnStart = historyCoordinator.allMessages.count

            // MARK: Phase step (one former graph-node visit)

            switch phase {
            case "fast_path":
                response = try await llmCall(tools: [], stage: .initial_response)
                phase = "final_response"

            case "researcher":
                let budget = classification == .build ? 8 : 5
                if visitCount >= budget {
                    phase = classification == .build ? "architect" : "analyst"
                } else {
                    let turn = try await llmCall(tools: explorationTools, stage: .tool_loop)
                    response = turn
                    visitCount += 1
                    if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                        _ = await commitAndExecute(toolCalls: toolCalls, response: turn, tools: explorationTools)
                        // The model used tools — stay so it can continue with
                        // the results in context.
                    } else {
                        phase = classification == .build ? "architect" : "analyst"
                    }
                }

            case "analyst", "architect":
                // Pass through an existing conversational answer — re-calling
                // the model produced a second, divergent answer that replaced
                // the one the user saw stream.
                if let existing = response, !(existing.content?.isEmpty ?? true) {
                    phase = phase == "analyst" ? "final_response" : "pm"
                } else {
                    let stage: AIRequestStage? = phase == "analyst" ? .initial_response : .tool_loop
                    let turn = try await llmCall(tools: explorationTools, stage: stage)
                    response = turn
                    if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                        _ = await commitAndExecute(toolCalls: toolCalls, response: turn, tools: explorationTools)
                    }
                    phase = phase == "analyst" ? "final_response" : "pm"
                }

            case "pm":
                // Drive the loop from the REAL plan when one exists (created
                // via plan(action: init)); fall back to 3 synthetic leaves.
                if taskPlan == nil,
                   let plan = await ConversationPlanStore.shared.getPlan(conversationId: request.conversationId) {
                    taskPlan = plan
                    planItemIndex = min(planItemIndex, plan.items.count)
                }
                let itemCount = taskPlan?.items.count ?? 3
                if planItemIndex >= itemCount {
                    phase = "final_response"
                } else {
                    planItemIndex += 1
                    phase = "leaf_executor"
                }

            case "leaf_executor":
                // Runner-driven closed loop: inject current PlanItem context and hide plan tool during execution
                let executionTools = taskPlan != nil ? request.availableTools.filter { $0.name != "plan" } : request.availableTools
                let focusedMessages: [ChatMessage]? = {
                    guard let plan = taskPlan, planItemIndex > 0, planItemIndex <= plan.items.count else { return nil }
                    let item = plan.items[planItemIndex - 1]
                    let focus = """
                    [Plan Item \(planItemIndex)/\(plan.items.count)] \(item.description)
                    Purpose: \(item.purpose)
                    Context: \(item.context.joined(separator: ", "))
                    Done when: \(item.doneCriteria)
                    — Execute ONLY this item with surgical tools (read/search + edit/write/bash). Do not call plan tool; runner will advance on completion.
                    """
                    var msgs = historyCoordinator.requestMessages
                    msgs.append(ChatMessage(role: .user, content: focus))
                    return msgs
                }()
                let turn = try await llmCall(tools: executionTools, stage: .tool_loop, messages: focusedMessages)
                response = turn
                if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                    let results = await commitAndExecute(toolCalls: toolCalls, response: turn, tools: executionTools)
                    // A tool that returned an error must be RETRIED with the
                    // error visible in context — otherwise the failed edit
                    // becomes the final answer ("My apologies...").
                    let hadToolErrors = results.contains {
                        $0.toolStatus == .failed
                            || $0.content.contains("status: error")
                            || $0.content.contains("error_code:")
                    }
                    if hadToolErrors, leafToolErrorRetryCount < Self.leafToolErrorRetryCap {
                        leafToolErrorRetryCount += 1
                    } else {
                        leafToolErrorRetryCount = 0
                        leafReworkCount = 0
                        phase = "leaf_review"
                    }
                } else {
                    phase = "leaf_review"
                }

            case "leaf_review":
                let turn = try await llmCall(tools: [], stage: .tool_loop)
                response = turn
                if let verdict = turn.content, !verdict.isEmpty {
                    // Commit the verdict so a retried leaf sees the corrections.
                    await historyCoordinator.append(
                        ChatMessage(role: .assistant, content: verdict,
                                    context: ChatMessageContentContext(codeContext: "Leaf review verdict"))
                    )
                }
                let verdict = turn.content ?? ""
                let needsRework = Self.verdictSignalsRework(verdict)
                if needsRework, leafReworkCount < Self.leafReworkCap {
                    leafReworkCount += 1
                    phase = "leaf_executor"
                } else {
                    // Runner marks PlanItem completed — model never calls plan.finishTask during execution
                    if var plan = taskPlan, planItemIndex > 0, planItemIndex <= plan.items.count {
                        plan.completeItem(at: planItemIndex - 1, summary: String(verdict.prefix(200)))
                        taskPlan = plan
                        await ConversationPlanStore.shared.setPlan(conversationId: request.conversationId, plan: plan)
                    }
                    leafReworkCount = 0
                    phase = "pm"
                }

            case "final_response":
                if let response, !(response.content ?? "").isEmpty {
                    return response
                }
                return try await summarizeFinal()

            default:
                throw AppError.unknown("AgentLoop: unknown phase '\(phase)'")
            }

            // MARK: P1 empty-response-after-work recovery (runner-level)

            if Self.isEmptyAfterWork(response, committedAtTurnStart: committedAtTurnStart, historyCoordinator: historyCoordinator) {
                emptyRecoveryCount += 1
                if emptyRecoveryCount <= Self.maxEmptyRecoveries {
                    await historyCoordinator.append(ChatMessage(
                        role: .user,
                        content: "Continue from where you left off — summarize progress so far and resume the task. Do not restart from the beginning."
                    ))
                    await appendSnapshot(phase: phase, iteration: transitionCount, response: response)
                    continue
                }
            } else if let response, Self.hasVisibleContent(response) {
                emptyRecoveryCount = 0
            }

            await appendSnapshot(phase: phase, iteration: transitionCount, response: response)
        }

        // P6: graceful finalize instead of throwing — jump to the summary path
        // so the run ends with a recap rather than an error toast.
        if phase != "final_response" {
            await historyCoordinator.append(ChatMessage(
                role: .user,
                content: "Approaching the step budget — wrap up now: summarize what has been completed and list any remaining steps."
            ))
            let final = try await summarizeFinal()
            await appendSnapshot(phase: "final_response", iteration: transitionCount, response: final)
            return final
        }

        if let response {
            return response
        }
        throw AppError.unknown("AgentLoop: graph ended without response")
    }

    // MARK: - Phase helpers

    private var startPhase: String {
        switch classification {
        case .fast: return "fast_path"
        case .review, .build: return "researcher"
        }
    }

    private var explorationTools: [AITool] {
        request.availableTools.filter { ToolTaxonomy.exploration.contains($0.name) }
    }

    private func llmCall(
        tools: [AITool],
        stage: AIRequestStage?,
        messages: [ChatMessage]? = nil
    ) async throws -> AIServiceResponse {
        try await aiCoordinator.sendMessageWithRetry(
            .init(
                messages: messages ?? historyCoordinator.requestMessages,
                tools: tools,
                mode: request.mode,
                projectRoot: projectRoot,
                runId: request.runId,
                stage: stage,
                conversationId: request.conversationId
            )
        ).get()
    }

    /// Commit the assistant tool-call message BEFORE its results — the cloud
    /// request builder drops tool results whose call id isn't in the committed
    /// assistant history (blind-loop bug).
    private func commitAndExecute(
        toolCalls: [AIToolCall],
        response: AIServiceResponse,
        tools: [AITool]
    ) async -> [ChatMessage] {
        let commitSplit = ReasoningSplitter.apply(to: response)
        await historyCoordinator.append(
            ChatMessage(role: .assistant,
                        content: ToolMarkupStripper.assistantContent(commitSplit.content, toolCalls: toolCalls),
                        context: ChatMessageContentContext(reasoning: commitSplit.reasoning),
                        tool: ChatMessageToolContext(toolCalls: toolCalls))
        )
        let results = await toolExecutor.executeToolCalls(
            toolCalls, availableTools: tools,
            conversationId: request.conversationId
        ) { _ in }
        for msg in results { await historyCoordinator.append(msg) }
        return results
    }

    /// FinalResponseNode semantics: pass through an existing answer, or
    /// synthesize a summary (with a work-done instruction when tool results
    /// are in history — the instruction is request-only, never committed).
    private func summarizeFinal() async throws -> AIServiceResponse {
        let messages = historyCoordinator.requestMessages
        let hadToolWork = messages.contains { $0.isToolExecution }
        let summaryInstruction = hadToolWork
            ? "The task could not be fully completed. Summarize the work that WAS done based on the tool results above, then list any remaining steps clearly. Do not claim work that wasn't performed."
            : nil

        var finalMessages = messages
        if let instruction = summaryInstruction {
            finalMessages.append(ChatMessage(role: .user, content: instruction))
        }

        return try await llmCall(tools: [], stage: .final_response, messages: finalMessages)
    }

    /// A verdict that signals the leaf FAILED must rework — string-matching is
    /// the production contract (LeafReviewNode.verdictSignalsRework).
    static func verdictSignalsRework(_ verdict: String) -> Bool {
        let upper = verdict.uppercased()
        if upper.contains("LEAF_FAIL") { return true }
        let failureSignals = [
            "MY APOLOGIES", "APOLOG", "I MISSED", "I FORGOT",
            "FAILED TO APPLY", "FAILED TO EXECUTE", "COULD NOT APPLY",
            "COULD NOT COMPLETE", "NOT APPLIED", "NOT YET APPLIED",
            "WILL RE-APPLY", "WILL RETRY", "RETRYING",
        ]
        return failureSignals.contains(where: { upper.contains($0) })
    }

    /// True when the phase returned an empty response (no content, no
    /// reasoning, no tool calls) but the history grew since the turn started —
    /// i.e. the model did real work then went silent, and we should recover.
    private static func isEmptyAfterWork(
        _ response: AIServiceResponse?,
        committedAtTurnStart: Int,
        historyCoordinator: ChatHistoryCoordinator
    ) -> Bool {
        guard let response else { return false }
        if !(response.toolCalls?.isEmpty ?? true) { return false }
        if hasVisibleContent(response) { return false }
        return historyCoordinator.allMessages.count > committedAtTurnStart
    }

    private static func hasVisibleContent(_ response: AIServiceResponse) -> Bool {
        let content = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { return true }
        let reasoning = (response.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !reasoning.isEmpty
    }

    // MARK: - Snapshots

    private func appendSnapshot(phase: String, iteration: Int, response: AIServiceResponse?) async {
        let snapshot = OrchestrationRunSnapshot(
            runId: request.runId,
            conversationId: request.conversationId,
            phase: phase,
            iteration: iteration,
            timestamp: Date(),
            userInput: request.userInput,
            assistantDraft: response?.content,
            failureReason: nil,
            toolCalls: (response?.toolCalls ?? []).map {
                OrchestrationRunSnapshot.ToolCallSummary(
                    id: $0.id,
                    name: $0.name,
                    argumentKeys: Array($0.arguments.keys).sorted()
                )
            },
            toolResults: [],
            planSummary: nil
        )
        try? await OrchestrationRunStore.shared.appendSnapshot(snapshot)
    }
}
