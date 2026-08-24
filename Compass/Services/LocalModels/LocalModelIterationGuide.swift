import Foundation

/// Provides per-iteration guidance to the local model to prevent
/// degenerate repetition loops. This is the local equivalent of
/// `AgentLoop`'s P1 empty-response recovery and plan-driven execution.
///
/// **Design rationale:**
/// - Follows the Strategy pattern: encapsulates "what to tell the model
///   between iterations" as a separate, testable component
/// - Matches the cloud path's correction prompt pattern
///   (`Prompts/ConversationFlow/Corrections/`)
/// - Open/Closed: new guidance strategies are added as new methods,
///   not by modifying the loop
struct LocalModelIterationGuide {

    // MARK: - Repetition detection

    /// Detects if the current tool call is a repeat of the previous one.
    /// Convenience wrapper over `detectBatchRepetition`.
    func detectRepetition(
        current: AIToolCall,
        previousToolCalls: [AIToolCall]
    ) -> RepetitionKind? {
        detectBatchRepetition(current: [current], previous: previousToolCalls)
    }

    /// Detects if the current tool-call batch repeats the previous batch.
    ///
    /// Compares canonicalized signatures of the FULL batches (order-
    /// insensitive within a batch), so a repeated call inside an otherwise
    /// larger batch is caught — comparing only `first` vs `last` misses that
    /// case (`[read:a]` followed by `[read:a, read:b]`).
    func detectBatchRepetition(
        current: [AIToolCall],
        previous: [AIToolCall]
    ) -> RepetitionKind? {
        guard let lastPrevious = previous.last else { return nil }
        guard let currentFirst = current.first else { return nil }
        guard currentFirst.name == lastPrevious.name || batchNamesOverlap(current, previous) else {
            return nil
        }

        let currentSignature = Self.canonicalBatchSignature(current)
        let previousSignature = Self.canonicalBatchSignature(previous)

        if currentSignature == previousSignature {
            return .identicalCall(name: currentFirst.name, arguments: currentFirst.arguments)
        }

        // Same tools, different arguments — likely a legitimate follow-up.
        return nil
    }

    private func batchNamesOverlap(_ a: [AIToolCall], _ b: [AIToolCall]) -> Bool {
        Set(a.map(\.name)).intersection(b.map(\.name)) != []
    }

    // MARK: - Corrective guidance

    /// Generates a corrective user message when repetition is detected.
    func correctiveMessage(for repetition: RepetitionKind, iteration: Int) -> String {
        switch repetition {
        case .identicalCall(let name, _):
            return """
            You already called \(name) with the same arguments in the previous \
            iteration. Do NOT repeat the same tool call. Instead:
            1. Analyze the tool result you already received
            2. Take a DIFFERENT action based on that result
            3. If the result was sufficient, produce a final answer for the user
            """
        case .similarCall(let name):
            return """
            You recently called \(name). Consider whether a different tool \
            would be more appropriate, or whether you have enough information \
            to provide a final answer.
            """
        case .noProgress:
            return """
            Continue from where you left off. Do NOT restart from the beginning. \
            Summarize progress so far and take the next logical step.
            """
        }
    }

    /// Generates guidance when the model needs to continue after tool execution.
    func continueGuidance(
        toolCalls: [AIToolCall],
        toolResults: [ChatMessage],
        iteration: Int
    ) -> String {
        let toolNames = toolCalls.map(\.name).joined(separator: ", ")
        return """
        You executed [\(toolNames)]. The results are above. \
        Based on these results, either:
        1. Take the next action (use a different tool if needed), or
        2. If you have enough information, produce a final answer for the user.
        Do NOT repeat the same tool call.
        """
    }

    /// Generates a summary prompt when the budget is exhausted.
    func finalizeMessage(
        completedIterations: Int,
        totalToolCalls: Int
    ) -> String {
        """
        You have used \(completedIterations) tool iterations (\(totalToolCalls) tool calls). \
        You must now produce a final answer. Summarize:
        1. What you discovered from the tool calls
        2. What the user should know or do next
        Do NOT make any more tool calls.
        """
    }

    // MARK: - Argument canonicalization

    /// Order-insensitive signature of a whole tool-call batch.
    private static func canonicalBatchSignature(_ calls: [AIToolCall]) -> [String] {
        calls
            .map { "\($0.name)#\(canonicalizeArguments($0.arguments))" }
            .sorted()
    }

    /// Canonicalizes tool call arguments for comparison.
    /// Handles the JSON round-tripping that produces Double/Int/String
    /// variants for the same logical value.
    private static func canonicalizeArguments(_ arguments: [String: Any]?) -> String {
        guard let arguments, !arguments.isEmpty else { return "" }

        // Sort keys for deterministic comparison
        let sortedKeys = arguments.keys.sorted()
        var parts: [String] = []
        for key in sortedKeys {
            let value = arguments[key]
            let canonical = canonicalValue(value)
            parts.append("\(key)=\(canonical)")
        }
        return parts.joined(separator: ";")
    }

    private static func canonicalValue(_ value: Any?) -> String {
        switch value {
        case let int as Int:
            return "\(int)"
        case let int64 as Int64:
            return "\(int64)"
        case let double as Double:
            return "\(double)"
        case let float as Float:
            return "\(float)"
        case let string as String:
            return string
        case let bool as Bool:
            return "\(bool)"
        case .none:
            return "nil"
        default:
            return String(describing: value ?? "nil")
        }
    }

    // MARK: - Types

    enum RepetitionKind: Equatable {
        case identicalCall(name: String, arguments: [String: Any]?)
        case similarCall(name: String)
        case noProgress

        static func == (lhs: RepetitionKind, rhs: RepetitionKind) -> Bool {
            switch (lhs, rhs) {
            case (.identicalCall(let n1, _), .identicalCall(let n2, _)):
                return n1 == n2
            case (.similarCall(let n1), .similarCall(let n2)):
                return n1 == n2
            case (.noProgress, .noProgress):
                return true
            default:
                return false
            }
        }
    }
}
