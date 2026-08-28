import Foundation
import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon

struct LocalModelPromptBuilder {

    func buildRawMessages(
        messages: [ChatMessage],
        explicitContext: String?,
        systemContent: String
    ) -> [[String: any Sendable]] {
        let merged = mergedSystemContent(
            messages: messages,
            explicitContext: explicitContext,
            systemContent: systemContent
        )

        var rawMessages: [[String: any Sendable]] = []
        rawMessages.append([
            "role": MessageRole.system.rawValue,
            "content": merged,
        ])

        for message in messages {
            if message.role == .system { continue }

            if message.role == .tool {
                let toolName = message.toolName ?? "unknown_tool"
                let toolContent = replayToolMessageContent(from: message)
                var toolDict: [String: any Sendable] = [
                    "role": "tool",
                    "content": toolContent,
                    "name": toolName,
                    "tool_responses": [
                        [
                            "name": toolName,
                            "response": toolContent,
                        ] as [String: any Sendable],
                    ] as [any Sendable],
                ]
                if let toolCallId = message.toolCallId, !toolCallId.isEmpty {
                    toolDict["tool_call_id"] = toolCallId
                }
                rawMessages.append(toolDict)
                continue
            }

            var rawMessage: [String: any Sendable] = [
                "role": message.role.rawValue,
                "content": message.content,
            ]

            // Reasoning is committed separately (ReasoningSplitter) — the
            // chat template renders `reasoning_content` back into <think>
            // for the replay, preserving what the model saw before.
            if message.role == .assistant,
               let reasoning = message.reasoning,
               !reasoning.isEmpty {
                rawMessage["reasoning_content"] = reasoning
            }

            if message.role == .assistant,
               let toolCalls = message.toolCalls,
               !toolCalls.isEmpty {
                rawMessage["tool_calls"] = toolCalls.map { toolCall in
                    [
                        "id": toolCall.id,
                        "type": "function",
                        "function": [
                            "name": toolCall.name,
                            "arguments": rawMessageValue(from: toolCall.arguments) as? [String: any Sendable] ?? [:],
                        ] as [String: any Sendable],
                    ] as [String: any Sendable]
                }
            }

            rawMessages.append(rawMessage)
        }

        return rawMessages
    }

    func mergedSystemContent(
        messages: [ChatMessage],
        explicitContext: String?,
        systemContent: String
    ) -> String {
        let normalizedContext = explicitContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let historicalSystemContent = messages
            .filter { $0.role == .system }
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ([systemContent] + (normalizedContext.map { ["Project context:\n\($0)"] } ?? []) + historicalSystemContent)
            .joined(separator: "\n\n")
    }

    func buildSystemContent(
        tools: [AITool]?,
        mode: AIMode?,
        stage: AIRequestStage? = nil,
        projectRoot: URL?,
        settings: OpenRouterSettings
    ) throws -> String {
        let pinnedRules: [String] = {
            if let root = projectRoot {
                return PinnedRulesStore.load(projectRoot: root)
            }
            return []
        }()
        let systemPrompt = try SystemPromptAssembler().assemble(
            input: .init(
                systemPromptOverride: settings.systemPrompt,
                hasTools: tools?.isEmpty == false,
                toolPromptMode: settings.toolPromptMode,
                mode: mode,
                projectRoot: projectRoot,
                reasoningMode: settings.reasoningMode,
                stage: stage,
                includeModelReasoning: settings.reasoningMode.includesModelReasoning && stage != .tool_loop,
                pinnedRules: pinnedRules,
                repoMap: nil
            )
        )
        var prompt = systemPrompt
        if settings.reasoningMode.includesModelReasoning && stage != .tool_loop {
            prompt += "\n\n" + ReasoningIntensity.current.systemPromptDirective
        }
        return prompt + "\n\n" + localModelResponseGuidance(mode: mode, stage: stage)
    }

    func budgetMessages(
        _ messages: [ChatMessage],
        explicitContext: String?,
        systemContent: String,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        approximateTokenCount: (String) -> Int
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }

        let reservedOutputTokens = inferenceConfiguration.maxOutputTokens
        let systemTokens = approximateTokenCount(systemContent)
        let explicitContextTokens = approximateTokenCount(explicitContext ?? "")
        let overheadTokens = 256
        let availableHistoryBudget = max(
            256,
            inferenceConfiguration.contextLength - reservedOutputTokens - systemTokens - explicitContextTokens - overheadTokens
        )

        var selected: [ChatMessage] = []
        var consumedTokens = 0

        // Keep the trailing tool exchange INTACT: an assistant tool-call
        // message followed by its tool results must not be split — the model
        // would re-issue calls it already executed (or see orphaned results).
        var pendingToolResults: [ChatMessage] = []
        var pendingToolCall: ChatMessage?
        for message in messages.reversed() {
            if message.role == .tool {
                pendingToolResults.append(message)
                continue
            }
            if message.role == .assistant, message.toolCalls != nil {
                pendingToolCall = message
                continue
            }
            if message.role == .assistant, pendingToolCall != nil {
                // previous iteration already captured a tool-call message
                // without its results — flush as-is below.
            }

            // Non-tool message: flush the captured exchange group first.
            var group: [ChatMessage] = []
            if let captured = pendingToolCall {
                group.append(captured)
                pendingToolCall = nil
            }
            group.append(contentsOf: pendingToolResults.reversed())
            pendingToolResults.removeAll()

            var groupTokens = 0
            for gm in group {
                groupTokens += approximateTokenCount(gm.content) + 16
            }
            let messageTokens = approximateTokenCount(message.content) + 16
            if consumedTokens + groupTokens + messageTokens <= availableHistoryBudget {
                // Keep the exchange group as a unit when it fits.
                // Because `selected` accumulates in reverse chronological order
                // (newest to oldest), append the newer `group` (in reverse)
                // before the older `message`.
                for gm in group.reversed() {
                    selected.append(gm)
                }
                selected.append(message)
                consumedTokens += groupTokens + messageTokens
                continue
            }

            // Group doesn't fit — preserve the newest user message. If that
            // one message itself exceeds the envelope, native preflight
            // rejects it rather than silently truncating user input.
            if selected.isEmpty, message.role == .user {
                selected.append(message)
                consumedTokens += messageTokens
            }
        }

        // Flush any trailing exchange captured at the loop end (newest to oldest).
        var trailingGroup: [ChatMessage] = []
        if let pendingToolCall {
            trailingGroup.append(pendingToolCall)
        }
        trailingGroup.append(contentsOf: pendingToolResults.reversed())
        for gm in trailingGroup.reversed() {
            selected.append(gm)
        }

        return selected.reversed()
    }

    func replayToolMessageContent(from message: ChatMessage) -> String {
        guard let envelope = ToolExecutionEnvelope.decode(from: message.content) else {
            return message.content
        }

        if let payload = envelope.payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty {
            return payload
        }

        let fallback = envelope.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? message.content : fallback
    }

    func convertToToolSpec(_ tools: [AITool]?) -> [[String: any Sendable]]? {
        guard let tools, !tools.isEmpty else { return nil }

        return tools.map { tool in
            let sendableParameters = convertToSendable(tool.parameters)

            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": sendableParameters
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        }
    }

    func additionalContext(
        for model: LocalModelDefinition,
        settings: OpenRouterSettings,
        stage: AIRequestStage?
    ) -> [String: any Sendable]? {
        // The single fixed chat model (Qwen3.5-4B) supports native
        // thinking via `enable_thinking` — unconditional.
        let enableThinking = settings.reasoningMode.includesModelReasoning && stage != .tool_loop
        return ["enable_thinking": enableThinking]
    }

    func defaultSamplingParameters(mode: AIMode?, stage: AIRequestStage?) -> (temperature: Float, topP: Float, repetitionPenalty: Float?, repetitionContextSize: Int) {
        if stage == .tool_loop || mode == .agent || mode == .coder {
            return (0.2, 0.9, 1.05, 64)
        }
        return (0.35, 0.92, 1.03, 64)
    }

    func localModelResponseGuidance(mode: AIMode?, stage: AIRequestStage?) -> String {
        var lines = [
            "Local response guidance:",
            "- Prefer the shortest response that fully solves the request.",
            "- Do not narrate obvious steps or repeat the user's request.",
            "- When the user asks for brevity, match it exactly and stop.",
            "- For coding help, prioritize code, edits, and direct conclusions over exposition."
        ]
        if mode == .agent || mode == .coder || stage == .tool_loop {
            lines.append("- During agent/tool work, keep status text condensed and action-oriented.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private func rawMessageValue(from value: Any) -> (any Sendable)? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return int
        case let int8 as Int8:
            return Int(int8)
        case let int16 as Int16:
            return Int(int16)
        case let int32 as Int32:
            return Int(int32)
        case let int64 as Int64:
            return Int(int64)
        case let uint as UInt:
            return Int(uint)
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number.doubleValue
        case let dictionary as [String: Any]:
            var sendableDictionary: [String: any Sendable] = [:]
            for (key, nestedValue) in dictionary {
                if let sendableValue = rawMessageValue(from: nestedValue) {
                    sendableDictionary[key] = sendableValue
                }
            }
            return sendableDictionary
        case let array as [Any]:
            return array.compactMap { rawMessageValue(from: $0) }
        case _ as NSNull:
            return nil
        default:
            return String(describing: value)
        }
    }

    private func convertToSendable(_ dictionary: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dictionary {
            if let sendable = rawMessageValue(from: value) {
                result[key] = sendable
            }
        }
        return result
    }
}
