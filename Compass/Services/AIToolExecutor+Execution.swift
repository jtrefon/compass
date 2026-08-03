import Foundation

extension AIToolExecutor {
    struct ToolExecutionCancelledError: LocalizedError, Sendable {
        var errorDescription: String? { "Tool execution cancelled." }
    }

    struct ToolExecutionTimedOutError: LocalizedError, Sendable {
        let timeoutSeconds: Int
        var guidance: String?
        var errorDescription: String? {
            if let guidance {
                "Tool execution timed out after \(timeoutSeconds)s.\n\(guidance)"
            } else {
                "Tool execution timed out after \(timeoutSeconds)s."
            }
        }
    }

    struct ToolExecutionCrashError: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    struct ToolExecutionMessageContext {
        let toolName: String
        let status: ToolExecutionStatus
        let targetFile: String?
        let toolCallId: String
        let preview: String?
        let argumentKeys: [String]?
        let argumentPreview: String?
        let recoveryHint: String?
        /// Normalized per-argument identity for the first-line envelope.
        let params: [String: String]?
    }

    struct ToolExecutionContextError: LocalizedError {
        let underlying: Error
        let argumentKeys: [String]
        let argumentPreview: String?
        let recoveryHint: String?

        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    struct ExecuteToolAndCaptureRequest: @unchecked Sendable {
        let tool: AITool
        let toolCall: AIToolCall
        let mergedArguments: [String: Any]
        let conversationId: String?
        let targetFile: String?
        let onProgress: @MainActor @Sendable (ChatMessage) -> Void
    }

    struct ExecuteToolCallRequest {
        let toolCall: AIToolCall
        let availableTools: [AITool]
        let conversationId: String?
        let onProgress: @MainActor @Sendable (ChatMessage) -> Void
        let targetFile: String?
    }

    struct MalformedMutationArgumentsError: LocalizedError {
        let toolName: String

        var errorDescription: String? {
            "Malformed arguments for \(toolName). Refusing to execute mutation with incomplete raw payload. Provide complete structured arguments before retrying."
        }
    }

    /// Normalize a tool-call's arguments into a compact `[String: String]` identity
    /// for the first-line execution envelope. Internal/bookkeeping keys (prefixed
    /// with `_`) and empty values are dropped. Values are stringified and truncated.
    nonisolated static func normalizedToolParams(_ arguments: [String: Any]?) -> [String: String]? {
        guard let arguments, !arguments.isEmpty else { return nil }
        var params: [String: String] = [:]
        for (key, value) in arguments {
            guard !key.hasPrefix("_") else { continue }
            let stringValue: String
            if let v = value as? String {
                stringValue = v
            } else if let v = value as? CustomStringConvertible {
                stringValue = v.description
            } else {
                continue
            }
            guard !stringValue.isEmpty else { continue }
            params[key] = stringValue
        }
        return params.isEmpty ? nil : params
    }

    nonisolated static func makeToolExecutionMessage(
        content: String,
        context: ToolExecutionMessageContext
    ) -> ChatMessage {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? nil : content
        let message: String

        switch context.status {
        case .executing:
            message = "Tool execution in progress."
        case .completed:
            message = payload == nil
                ? "Tool completed with no payload."
                : "Tool completed successfully."
        case .failed:
            message = trimmed.isEmpty
                ? "Tool failed with no error details."
                : content
        }

        let envelope = ToolExecutionEnvelope(
            status: context.status,
            message: message,
            payload: context.status == .failed ? nil : payload,
            preview: context.preview,
            toolName: context.toolName,
            toolCallId: context.toolCallId,
            targetFile: context.targetFile,
            argumentKeys: context.argumentKeys,
            argumentPreview: context.argumentPreview,
            recoveryHint: context.recoveryHint,
            params: context.params
        )

        return ChatMessage(
            role: .tool,
            content: envelope.encodedString(),
            tool: ChatMessageToolContext(
                toolName: context.toolName,
                toolStatus: context.status,
                target: ToolInvocationTarget(
                    targetFile: context.targetFile,
                    toolCallId: context.toolCallId
                )
            )
        )
    }

    nonisolated static func buildInvocationPreview(
        toolName: String,
        targetFile: String?,
        arguments: [String: Any]
    ) -> String? {
        func trim(_ value: String, limit: Int) -> String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count > limit else { return normalized }
            let prefix = normalized.prefix(limit)
            return "\(prefix)\n…"
        }

        func stringArg(_ key: String) -> String? {
            guard let value = arguments[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func intArg(_ key: String) -> Int? {
            if let value = arguments[key] as? Int { return value }
            if let value = arguments[key] as? Int32 { return Int(value) }
            if let value = arguments[key] as? Int64 { return Int(value) }
            if let value = arguments[key] as? Double { return Int(value) }
            if let value = arguments[key] as? NSNumber { return value.intValue }
            if let value = arguments[key] as? String, let parsed = Int(value) { return parsed }
            return nil
        }

        let filePath = targetFile ?? stringArg("path")

        switch toolName {
        case "edit", "replace_in_file":
            guard let oldText = stringArg("old_text"), let newText = stringArg("new_text") else {
                return filePath.map { "Edit file: \($0)" }
            }

            let fileLabel = filePath ?? "(unspecified file)"
            return """
            Proposed edit: \(fileLabel)

            --- before
            \(trim(oldText, limit: 700))

            +++ after
            \(trim(newText, limit: 700))
            """

        case "write", "write_file", "create_file":
            guard let content = stringArg("content") else {
                return filePath.map { "Write file: \($0)" }
            }
            let fileLabel = filePath ?? "(unspecified file)"
            return """
            Write file: \(fileLabel)

            \(trim(content, limit: 1400))
            """

        case "rm", "delete_file":
            if let filePath {
                return "Delete file: \(filePath)"
            }
            return "Delete file request"

        case "bash", "run_command":
            let action = stringArg("action") ?? "start"
            let sessionId = stringArg("session_id")
            let command = stringArg("command") ?? "(missing command)"
            let workingDirectory = stringArg("working_directory")
            if action != "start" {
                var lines = ["Action: \(action)"]
                if let sessionId {
                    lines.append("Session: \(sessionId)")
                }
                if let input = stringArg("input"), !input.isEmpty {
                    lines.append("Input: \(trim(input, limit: 120))")
                }
                return lines.joined(separator: "\n")
            }
            if let workingDirectory {
                return """
                Command: \(trim(command, limit: 280))
                CWD: \(workingDirectory)
                """
            }
            return "Command: \(trim(command, limit: 280))"

        case "read", "read_file":
            let fileLabel = filePath ?? "(unspecified file)"

            let startLine = intArg("start_line") ?? intArg("offset")
            let endLine: Int? = {
                if let explicitEnd = intArg("end_line") {
                    return explicitEnd
                }
                if let startLine, let limit = intArg("limit"), limit > 0 {
                    return startLine + max(0, limit - 1)
                }
                return nil
            }()

            if let startLine, let endLine, endLine >= startLine {
                return "Read file: \(fileLabel)\nLines: \(startLine)-\(endLine)"
            }

            if let startLine {
                return "Read file: \(fileLabel)\nFrom line: \(startLine)"
            }

            return "Read file: \(fileLabel)"

        default:
            if let filePath {
                return "Target file: \(filePath)"
            }
            return nil
        }
    }

    func buildMergedArguments(toolCall: AIToolCall, conversationId: String?) async -> [String: Any] {
        var mergedArguments = toolCall.arguments
        mergedArguments["_tool_call_id"] = toolCall.id
        if let conversationId {
            mergedArguments["_conversation_id"] = conversationId
        }

        let resolvedArguments = await argumentResolver.buildMergedArguments(
            toolCall: toolCall,
            conversationId: conversationId
        )

        for (key, value) in resolvedArguments {
            mergedArguments[key] = value
        }

        return mergedArguments
    }

    func executeToolAndCaptureResult(
        _ request: ExecuteToolAndCaptureRequest
    ) async throws -> String {
        return try await request.tool.execute(arguments: ToolArguments(request.mergedArguments))
    }

    func makeToolCallFinalMessage(
        result: Result<String, Error>,
        toolCall: AIToolCall,
        targetFile: String?,
        preview: String?
    ) -> ChatMessage {
        switch result {
        case .success(let content):
            return Self.makeToolExecutionMessage(
                content: content,
                context: ToolExecutionMessageContext(
                    toolName: toolCall.name,
                    status: .completed,
                    targetFile: targetFile,
                    toolCallId: toolCall.id,
                    preview: preview,
                    argumentKeys: nil,
                    argumentPreview: nil,
                    recoveryHint: nil,
                    params: Self.normalizedToolParams(toolCall.arguments)
                )
            )
        case .failure(let error):
            let errorContent = Self.formatError(error, toolName: toolCall.name)
            let contextError = error as? ToolExecutionContextError
            return Self.makeToolExecutionMessage(
                content: errorContent,
                context: ToolExecutionMessageContext(
                    toolName: toolCall.name,
                    status: .failed,
                    targetFile: targetFile,
                    toolCallId: toolCall.id,
                    preview: preview,
                    argumentKeys: contextError?.argumentKeys,
                    argumentPreview: contextError?.argumentPreview,
                    recoveryHint: contextError?.recoveryHint,
                    params: Self.normalizedToolParams(toolCall.arguments)
                )
            )
        }
    }

    func executeToolCall(
        _ request: ExecuteToolCallRequest
    ) async -> ChatMessage {
        await logToolExecuteStart(
            conversationId: request.conversationId,
            toolCall: request.toolCall,
            targetFile: request.targetFile
        )

        // Begin tool execution activity for power management
        let activityToken = activityCoordinator?.beginActivity(type: .toolExecution)
        
        let resultMessage = await resolveToolAndExecute(request)

        // End tool execution activity
        activityToken?.end()

        Task { @MainActor in
            request.onProgress(resultMessage)
        }

        return resultMessage
    }

    private func resolveToolAndExecute(
        _ request: ExecuteToolCallRequest
    ) async -> ChatMessage {
        guard let tool = resolveTool(for: request.toolCall, from: request.availableTools) else {
            await logToolNotFound(conversationId: request.conversationId, toolCall: request.toolCall)
            return makeToolNotFoundMessage(request)
        }

        let preview = Self.buildInvocationPreview(
            toolName: request.toolCall.name,
            targetFile: request.targetFile,
            arguments: request.toolCall.arguments
        )
        let result = await executeKnownTool(tool, request: request)
        return makeToolCallFinalMessage(
            result: result,
            toolCall: request.toolCall,
            targetFile: request.targetFile,
            preview: preview
        )
    }

    private func resolveTool(for toolCall: AIToolCall, from availableTools: [AITool]) -> AITool? {
        if let directMatch = availableTools.first(where: { $0.name == toolCall.name }) {
            return directMatch
        }

        let canonical = ToolAliasRegistry.shared.canonicalName(for: toolCall.name)
        guard canonical != toolCall.name.lowercased() else { return nil }

        // Try exact canonical match first, then the legacy names that map to it
        let candidates = [canonical] + ToolAliasRegistry.shared.legacyNames(for: canonical)

        for candidate in candidates {
            if let resolved = availableTools.first(where: { $0.name == candidate }) {
                Task {
                    await AIToolTraceLogger.shared.log(
                        type: "tool.alias_resolved",
                        data: ["requested": toolCall.name, "resolved": candidate, "toolCallId": toolCall.id]
                    )
                }
                return resolved
            }
        }

        return nil
    }

    private func executeKnownTool(
        _ tool: AITool,
        request: ExecuteToolCallRequest
    ) async -> Result<String, Error> {
        let timeoutSeconds = resolveToolTimeoutSeconds(
            toolName: request.toolCall.name,
            arguments: request.toolCall.arguments
        )
        let toolExecStart = ContinuousClock.now
        var mergedArguments: [String: Any] = [:]

        do {
            mergedArguments = await buildMergedArguments(
                toolCall: request.toolCall,
                conversationId: request.conversationId
            )

            try validateMutationArgumentsBeforeExecution(
                toolCall: request.toolCall,
                mergedArguments: mergedArguments
            )

            try runPreWritePreventionIfNeeded(
                toolCall: request.toolCall,
                mergedArguments: mergedArguments
            )
        } catch {
            let enriched = Self.enrichError(
                error,
                toolName: request.toolCall.name,
                arguments: mergedArguments,
                originalArguments: request.toolCall.arguments,
                targetFile: request.targetFile
            )
            await logToolExecuteError(
                conversationId: request.conversationId,
                toolCall: request.toolCall,
                error: enriched
            )
            return .failure(enriched)
        }

        // Writes to the same target path are serialized so concurrent tool
        // calls cannot interleave edits to one file. The timeout deadline
        // starts when the write actually begins, not while it is queued.
        let pathKey = request.targetFile
            ?? argumentResolver.resolveTargetFile(for: request.toolCall)
            ?? ""

        let content: String
        do {
            content = try await scheduler.runWriteTask(
                pathKey: isWriteLikeTool(request.toolCall.name) ? pathKey : ""
            ) { @MainActor in
                ToolTimeoutCenter.shared.begin(
                    toolCallId: request.toolCall.id,
                    toolName: request.toolCall.name,
                    targetFile: request.targetFile,
                    timeoutSeconds: timeoutSeconds
                )
                defer {
                    ToolTimeoutCenter.shared.finish(toolCallId: request.toolCall.id)
                }
                return try await executeToolAndCaptureResultWithWatchdog(
                    tool: tool,
                    toolCall: request.toolCall,
                    mergedArguments: mergedArguments,
                    conversationId: request.conversationId,
                    targetFile: request.targetFile,
                    onProgress: request.onProgress,
                    timeoutSeconds: timeoutSeconds
                )
            }
            await logToolExecuteSuccess(
                conversationId: request.conversationId,
                toolCall: request.toolCall,
                resultLength: content.count
            )
            if Self.isCommandTool(request.toolCall.name) {
                await ToolTimeoutCircuitBreaker.shared.reset(
                    normalizedKey: Self.commandBreakerKey(
                        tool: request.toolCall.name,
                        arguments: request.toolCall.arguments
                    )
                )
            }
            return .success(content)
        } catch {
            // Circuit breaker: repeated identical `run_command` timeouts usually
            // mean a long-running or hung process, not a transient blip. Trip
            // after a few consecutive occurrences and tell the model to stop
            // retrying blindly (use background sessions instead).
            if let timeoutError = error as? ToolExecutionTimedOutError,
               Self.isCommandTool(request.toolCall.name) {
                let key = Self.commandBreakerKey(
                    tool: request.toolCall.name,
                    arguments: request.toolCall.arguments
                )
                let (tripped, count) = await ToolTimeoutCircuitBreaker.shared.record(normalizedKey: key)
                if tripped {
                    let breaker = ToolExecutionTimedOutError(
                        timeoutSeconds: timeoutError.timeoutSeconds,
                        guidance: """
                        [Circuit breaker] This command has timed out \(count) times in a row. \
                        It is likely long-running (e.g. a dev server, watch mode, or build) or hung — \
                        STOP re-issuing it. To run a long-running process, call run_command with \
                        action=start (which returns a session_id you can poll with action=wait), then \
                        use action=wait to read more output and action=stop to terminate it.
                        """
                    )
                    await logToolExecuteError(
                        conversationId: request.conversationId,
                        toolCall: request.toolCall,
                        error: breaker
                    )
                    return .failure(breaker)
                }
            }

            let enriched = Self.enrichError(
                error,
                toolName: request.toolCall.name,
                arguments: mergedArguments,
                originalArguments: request.toolCall.arguments,
                targetFile: request.targetFile
            )
            await logToolExecuteError(
                conversationId: request.conversationId,
                toolCall: request.toolCall,
                error: enriched
            )
            return .failure(enriched)
        }
    }

    private func validateMutationArgumentsBeforeExecution(
        toolCall: AIToolCall,
        mergedArguments: [String: Any]
    ) throws {
        guard mergedArguments["_raw_args_chunk"] != nil else { return }

        switch toolCall.name {
        case "write", "write_file", "create_file":
            guard let path = mergedArguments["path"] as? String,
                  let content = mergedArguments["content"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !content.isEmpty else {
                throw MalformedMutationArgumentsError(toolName: toolCall.name)
            }
        case "edit", "replace_in_file":
            guard let path = mergedArguments["path"] as? String,
                  let oldText = mergedArguments["old_text"] as? String,
                  let newText = mergedArguments["new_text"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !oldText.isEmpty,
                  !newText.isEmpty else {
                throw MalformedMutationArgumentsError(toolName: toolCall.name)
            }
        case "write_files":
            guard let files = mergedArguments["files"] as? [[String: Any]], !files.isEmpty else {
                throw MalformedMutationArgumentsError(toolName: toolCall.name)
            }
            let allEntriesValid = files.allSatisfy { entry in
                guard let path = entry["path"] as? String,
                      let content = entry["content"] as? String else { return false }
                return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !content.isEmpty
            }
            guard allEntriesValid else {
                throw MalformedMutationArgumentsError(toolName: toolCall.name)
            }
        default:
            break
        }
    }

    private func resolveToolTimeoutSeconds(
        toolName: String,
        arguments: [String: Any]
    ) -> TimeInterval {
        if toolName == "bash" || toolName == "run_command" {
            let explicitWait = parseRunCommandWaitSeconds(arguments)
            let effectiveWait = explicitWait ?? 30
            return max(effectiveWait + 5, 15)
        }

        // Web tools: bounded timeout to prevent indefinite hangs
        if toolName == "web_search" || toolName == "web_fetch" || toolName == "web_browse" {
            return 35
        }

        // Search project: bounded timeout — semantic/symbol/full-text should be fast
        if toolName == "search" || toolName == "search_project" {
            return 30
        }

        let stored = UserDefaults.standard.double(forKey: AppConstantsStorage.cliTimeoutSecondsKey)
        // Default to 120s for npm operations, up to 600s max
        let normalized = stored == 0 ? 120 : stored
        return max(1, min(600, normalized))
    }
}
