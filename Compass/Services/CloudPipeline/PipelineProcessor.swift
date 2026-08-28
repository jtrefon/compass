import Foundation

enum PipelineProcessor {
    /// Default provider context window in tokens when no custom override is
    /// configured. Models vary below this in practice; the real ceiling comes
    /// from `CustomEndpointSettingsStore.contextOverride` when set.
    static let defaultContextWindowTokens = 262_000

    /// Requests are bounded to a fraction of the model's window so the provider
    /// always has head-room for the completion (output tokens + the current
    /// turn's tool results arrive after the bounded prefix).
    static let softBudgetFraction = 3.0 / 4.0

    /// Prepares the message list for a provider request.
    ///
    /// - Bounded: when the conversation exceeds the provider's context window,
    ///   keeps the leading system messages plus the newest tail (≈4 chars/token)
    ///   so long sessions don't overflow the provider and fail with 400s. The
    ///   bound uses the ACTIVE model's real window when known (via
    ///   `ModelContextRegistry`), falling back to the default.
    /// - Immutable: committed history is never mutated — truncation applies to
    ///   the request-time view only (the UI keeps the full chain).
    /// - Pair-safe: never starts a truncated request with an orphaned
    ///   tool-result message.
    /// - Cache-friendly: `preservesCache` (local-model prefix cache) skips
    ///   truncation — prefix reuse is worth more than a bounded window there.
    static func prepareForRequest(
        messages: [ChatMessage],
        modelID: String?,
        preservesCache: Bool,
        runId: String?,
        stage: AIRequestStage?
    ) -> [ChatMessage] {
        guard !preservesCache else { return messages }

        let budgetTokens = requestTokenBudget(modelID: modelID)
        let budgetChars = max(1, budgetTokens * 4)
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > budgetChars else { return messages }

        var head: [ChatMessage] = []
        var cursor = 0
        while cursor < messages.count, messages[cursor].role == .system {
            head.append(messages[cursor])
            cursor += 1
        }

        var tail: [ChatMessage] = []
        var used = head.reduce(0) { $0 + $1.content.count }
        var index = messages.count - 1

        // P3: walk the tail in tool units so truncation never splits a tool
        // call from its results. A "tool unit" is an assistant message with
        // toolCalls plus the tool-result messages that follow it. A leading
        // unit whose assistant call doesn't fit is dropped wholesale — an
        // orphaned tool result must never be sent alone.
        while index >= cursor {
            let unitSize = toolUnitSize(messages: messages, endingAt: index)
            let nextUsed = used + unitChars(messages: messages, endingAt: index, unitSize: unitSize)
            if nextUsed <= budgetChars || tail.isEmpty {
                for unitIndex in (index - (unitSize - 1))...index {
                    tail.insert(messages[unitIndex], at: 0)
                }
                used = nextUsed
                index -= unitSize
            } else {
                break
            }
        }

        // P3: final guard — never start the request with a bare tool-result
        // message (the unit walk above already prevents this for well-formed
        // history, but keep the invariant for unusual message shapes).
        while tail.count > 1, tail.first?.role == .tool {
            tail.removeFirst()
        }

        let result = head + tail
        let dropped = messages.count - result.count
        if dropped > 0 {
            Task {
                await AppLogger.shared.info(
                    category: .ai,
                    message: "context.truncated",
                    context: AppLogger.LogCallContext(metadata: [
                        "droppedMessages": dropped,
                        "budgetTokens": budgetTokens,
                        "totalMessages": messages.count
                    ])
                )
            }
        }
        return result
    }

    /// Provider context window in tokens: custom-endpoint override, else the
    /// ACTIVE model's window (via ModelContextRegistry) when known, else the
    /// default. The soft budget keeps head-room for output + the current
    /// turn's tool results.
    static func requestTokenBudget(modelID: String? = nil) -> Int {
        let override = CustomEndpointSettingsStore().load(includeApiKey: false).contextOverride
        if override > 0 { return override }
        if let modelID, let window = ModelContextRegistry.shared.contextLength(for: modelID), window > 0 {
            return Int(Double(window) * softBudgetFraction)
        }
        return defaultContextWindowTokens
    }

    // MARK: - Tool-unit walking (P3)

    /// Size of the tool unit ending at `endingAt`: for an assistant message
    /// with toolCalls, that's 1 (the call itself) — its results are appended
    /// as separate `.tool` messages AFTER it, so walking backwards the unit is
    /// (results..., assistant-call). When `endingAt` points at a `.tool`
    /// message, the unit extends back to its matching assistant call so the
    /// pair is never split.
    private static func toolUnitSize(messages: [ChatMessage], endingAt index: Int) -> Int {
        let msg = messages[index]
        if msg.role != .tool { return 1 }
        guard let callId = msg.toolCallId else { return 1 }
        // Walk back to the assistant message that declared this toolCallId.
        var cursor = index - 1
        while cursor >= 0 {
            let candidate = messages[cursor]
            if let calls = candidate.toolCalls, calls.contains(where: { $0.id == callId }) {
                return index - cursor + 1
            }
            if candidate.role == .user || candidate.role == .system { break }
            cursor -= 1
        }
        return 1
    }

    private static func unitChars(messages: [ChatMessage], endingAt index: Int, unitSize: Int) -> Int {
        var total = 0
        let start = max(0, index - (unitSize - 1))
        for i in start...index {
            total += messages[i].content.count
        }
        return total
    }
}
