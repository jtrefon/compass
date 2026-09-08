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
        // Stage-invariant for KV stability: tool_loop vs other must not change system prefix (live 17398→8281)
        let stableStage: AIRequestStage? = nil
        let systemPrompt = try SystemPromptAssembler().assemble(
            input: .init(
                systemPromptOverride: settings.systemPrompt,
                hasTools: tools?.isEmpty == false,
                toolPromptMode: settings.toolPromptMode,
                mode: mode,
                projectRoot: projectRoot,
                reasoningMode: settings.reasoningMode,
                stage: stableStage,
                includeModelReasoning: settings.reasoningMode.includesModelReasoning,
                pinnedRules: pinnedRules,
                repoMap: nil
            )
        )
        var prompt = systemPrompt
        // Stage-invariant: the reasoning directive must be byte-identical
        // across iterations (tool_loop included) or the KV prefix hash
        // changes mid-run and forces a full re-prefill. It also guarantees
        // MAX reasoning applies to tool loops, not just the final response.
        if settings.reasoningMode.includesModelReasoning {
            prompt += "\n\n" + ReasoningIntensity.current.systemPromptDirective
        }
        return prompt + "\n\n" + localModelResponseGuidance(mode: mode, stage: stage)
    }

    /// Immutable-context budget: messages are NEVER dropped. If the total
    /// prompt exceeds the context window, system content is truncated to make
    /// room. This preserves the append-only KV cache prefix — the same
    /// messages always produce the same token stream.
    ///
    /// Returns the computed `messageTokens` total so callers (telemetry) never
    /// need to re-encode the history — full-history BPE encode is seconds of
    /// CPU at 50K context and was previously run 3x per send.
    ///
    /// NOTE: With Mission Control, this truncation path is superseded by
    /// controlled resets (see 05-eviction-and-reset.md). The system prompt
    /// is never truncated — instead, a controlled reset fires at 75% context
    /// usage and rebuilds the context from Mission Control + protected reads.
    /// This method is kept for backward compatibility until the migration is
    /// complete.
    func budgetMessages(
        _ messages: [ChatMessage],
        explicitContext: String?,
        systemContent: String,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        approximateTokenCount: (String) -> Int
    ) -> (messages: [ChatMessage], adjustedSystemContent: String, messageTokens: Int) {
        guard !messages.isEmpty else { return (messages, systemContent, 0) }

        let reservedOutputTokens = inferenceConfiguration.maxOutputTokens
        let overheadTokens = 256
        let availableBudget = max(
            256,
            inferenceConfiguration.contextLength - reservedOutputTokens - overheadTokens
        )

        func renderedContent(_ message: ChatMessage) -> String {
            message.role == .tool ? replayToolMessageContent(from: message) : message.content
        }

        // Count all message tokens — messages are immutable, never dropped
        var messageTokens = 0
        for message in messages {
            messageTokens += approximateTokenCount(renderedContent(message)) + 16
        }

        let systemTokens = approximateTokenCount(systemContent) + approximateTokenCount(explicitContext ?? "")
        let totalTokens = messageTokens + systemTokens

        // Everything fits — no truncation needed
        if totalTokens <= availableBudget {
            return (messages, systemContent, messageTokens)
        }

        // Messages don't fit — truncate system content to make room.
        let systemBudget = max(256, availableBudget - messageTokens)
        let truncatedSystem = truncateToTokenBudget(systemContent, tokenBudget: systemBudget, approximateTokenCount: approximateTokenCount)

        return (messages, truncatedSystem, messageTokens)
    }

    /// Truncate a string to fit within a token budget, cutting at paragraph
    /// boundaries when possible.
    private func truncateToTokenBudget(
        _ text: String,
        tokenBudget: Int,
        approximateTokenCount: (String) -> Int
    ) -> String {
        let currentTokens = approximateTokenCount(text)
        if currentTokens <= tokenBudget { return text }

        // Try cutting at paragraph boundaries
        let paragraphs = text.components(separatedBy: "\n\n")
        var result = ""
        for paragraph in paragraphs {
            let candidate = result.isEmpty ? paragraph : result + "\n\n" + paragraph
            if approximateTokenCount(candidate) > tokenBudget {
                break
            }
            result = candidate
        }
        if !result.isEmpty { return result }

        // Hard cut at character boundary
        let charsPerToken = Double(text.count) / max(1, Double(currentTokens))
        let targetChars = Int(Double(tokenBudget) * charsPerToken * 0.9)
        return String(text.prefix(max(1, targetChars)))
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

        return tools.sorted { $0.name < $1.name }.map { tool in
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
        let enableThinking = settings.reasoningMode.includesModelReasoning
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
        if mode == .agent || mode == .coder {
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
