import Foundation

/// Per-iteration telemetry for the local model tool loop.
/// Writes structured entries to `.ide/logs/ai-trace.ndjson` for
/// post-hoc analysis of "what did the model actually see."
///
/// **Design rationale:**
/// - Follows the existing `AIToolTraceLogger` pattern (NDJSON file writer)
/// - Single Responsibility: observes loop iterations, does not influence them
/// - Structured data enables automated analysis (grep, jq, dashboards)
struct LocalModelToolLoopLogger {

    // MARK: - Iteration lifecycle

    func logIterationStart(
        iteration: Int,
        stage: AIRequestStage?,
        messageCount: Int
    ) async {
        await AIToolTraceLogger.shared.log(
            type: "local_loop.iteration_start",
            data: [
                "iteration": iteration,
                "stage": stage?.rawValue ?? "nil",
                "messageCount": messageCount,
            ]
        )
    }

    func logIterationComplete(
        iteration: Int,
        toolCalls: [AIToolCall],
        toolResults: [ChatMessage],
        committedCount: Int
    ) async {
        let toolCallSummary = toolCalls.map { call in
            [
                "id": call.id,
                "name": call.name,
                "argumentsPreview": String(describing: call.arguments).prefix(100),
            ] as [String: any Sendable]
        }

        let toolResultSummary = toolResults.map { msg in
            [
                "toolCallId": msg.toolCallId ?? "",
                "contentLength": msg.content.count,
                "status": msg.toolStatus?.rawValue ?? "",
            ] as [String: any Sendable]
        }

        await AIToolTraceLogger.shared.log(
            type: "local_loop.iteration_complete",
            data: [
                "iteration": iteration,
                "toolCalls": toolCallSummary as [any Sendable],
                "toolResults": toolResultSummary as [any Sendable],
                "committedCount": committedCount,
            ]
        )
    }

    // MARK: - Repetition detection

    func logRepetition(
        iteration: Int,
        currentCall: AIToolCall,
        previousCall: AIToolCall,
        identicalArguments: Bool
    ) async {
        await AIToolTraceLogger.shared.log(
            type: "local_loop.repetition",
            data: [
                "iteration": iteration,
                "toolName": currentCall.name,
                "identicalArguments": identicalArguments,
                "previousToolCallId": previousCall.id,
                "currentToolCallId": currentCall.id,
            ]
        )
    }

    // MARK: - Budget exhaustion

    func logBudgetExhaustion(
        iteration: Int,
        maxIterations: Int,
        totalToolCalls: Int
    ) async {
        await AIToolTraceLogger.shared.log(
            type: "local_loop.budget_exhaustion",
            data: [
                "iteration": iteration,
                "maxIterations": maxIterations,
                "totalToolCalls": totalToolCalls,
            ]
        )
    }
}
