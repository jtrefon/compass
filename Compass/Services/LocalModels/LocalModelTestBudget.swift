import Foundation

/// Overrides the inference budget (context length / max output tokens) when a
/// benchmark-style request is being driven by the offline harness. Reads the
/// same env variables `run.sh` forwards to the test process.
struct LocalModelTestBudget {
    let contextLength: Int
    let maxOutputTokens: Int
    /// Message list actually sent to the model — truncated under a benchmark
    /// budget so budgeted runs stay bounded.
    let retainedMessages: [ChatMessage]

    static func applyIfNeeded(
        to request: AIServiceHistoryRequest,
        contextLength: Int,
        launchContext: AppLaunchContext
    ) -> LocalModelTestBudget {
        let env = ProcessInfo.processInfo.environment
        let budgetContext = env["COMPASS_OFFLINE_BENCHMARK_CONTEXTS"].flatMap(Int.init) ?? 0
        let budgetOutput = env["COMPASS_OFFLINE_BENCHMARK_MAX_OUTPUTS"].flatMap(Int.init) ?? 0

        guard launchContext.isTesting, budgetContext > 0 || budgetOutput > 0 else {
            return LocalModelTestBudget(
                contextLength: contextLength,
                maxOutputTokens: 4096,
                retainedMessages: request.messages
            )
        }
        let maxMessages = 32
        let retained = request.messages.count > maxMessages
            ? Array(request.messages.suffix(maxMessages))
            : request.messages
        return LocalModelTestBudget(
            contextLength: budgetContext,
            maxOutputTokens: budgetOutput,
            retainedMessages: retained
        )
    }
}
