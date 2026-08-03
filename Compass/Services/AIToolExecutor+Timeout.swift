import Foundation

extension AIToolExecutor {
    // MARK: - Timeout circuit breaker helpers

    static func isCommandTool(_ toolName: String) -> Bool {
        toolName == "bash" || toolName == "run_command" || toolName == "run_shell"
    }

    /// Normalized identity for the circuit breaker: the tool plus the command
    /// being run (ignoring transient flags like wait_seconds so repeated
    /// identical commands trip the breaker regardless of timeout tweaks).
    static func commandBreakerKey(
        tool: String,
        arguments: [String: Any]
    ) -> String {
        let command = (arguments["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(tool):\(command)"
    }

    func parseRunCommandWaitSeconds(_ arguments: [String: Any]) -> TimeInterval? {
        let value = arguments["wait_seconds"] ?? arguments["timeout_seconds"]
        return ToolArgumentCoercion.asDouble(value)
    }

    func runPreWritePreventionIfNeeded(
        toolCall: AIToolCall,
        mergedArguments: [String: Any]
    ) throws {
        guard supportsPreWritePrevention(toolName: toolCall.name) else {
            return
        }

        let candidateFileCount = candidateFileCountForPrevention(toolName: toolCall.name, arguments: mergedArguments)
        eventBus?.publish(
            PreWritePreventionCheckStartedEvent(
                toolName: toolCall.name,
                candidateFileCount: candidateFileCount
            )
        )

        let allowOverride = preventionOverrideEnabled(arguments: mergedArguments)
        let result = preventionEngine.check(
            toolName: toolCall.name,
            arguments: mergedArguments,
            allowOverride: allowOverride
        )

        for finding in result.findings {
            switch finding.findingType {
            case .duplicateImpl:
                eventBus?.publish(
                    DuplicateRiskDetectedEvent(
                        summary: finding.explanation,
                        severity: finding.severity.rawValue
                    )
                )
            case .deadCodeRisk:
                eventBus?.publish(
                    DeadCodeRiskDetectedEvent(
                        summary: finding.explanation,
                        severity: finding.severity.rawValue
                    )
                )
            case .parallelPathRisk, .orphanAPI:
                break
            }
        }

        let guardStatus = guardStatusLabel(outcome: result.outcome)
        eventBus?.publish(
            DebtPressureUpdatedEvent(
                duplicateRiskCount: result.duplicateRiskCount,
                deadCodeRiskCount: result.deadCodeRiskCount,
                guardStatus: guardStatus
            )
        )
        eventBus?.publish(
            PreWritePreventionCheckCompletedEvent(
                toolName: toolCall.name,
                outcome: result.outcome.rawValue,
                findingCount: result.findings.count
            )
        )

        if result.outcome == .block {
            throw AppError.aiServiceError(
                "Pre-write prevention blocked tool '\(toolCall.name)'. Resolve duplicate/dead-code findings or pass prevention_override=true with justification.\n\n\(result.summary)"
            )
        }
    }

    func supportsPreWritePrevention(toolName: String) -> Bool {
        switch toolName {
        case "write", "write_file", "write_files", "create_file", "edit", "replace_in_file":
            return true
        default:
            return false
        }
    }

    func preventionOverrideEnabled(arguments: [String: Any]) -> Bool {
        if let boolValue = arguments["prevention_override"] as? Bool {
            return boolValue
        }

        if let textValue = arguments["prevention_override"] as? String {
            let normalized = textValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }

        return false
    }

    func candidateFileCountForPrevention(toolName: String, arguments: [String: Any]) -> Int {
        if toolName == "write" || toolName == "write_files" {
            if let files = arguments["files"] as? [[String: Any]] {
                return files.count
            }
        }

        if let path = arguments["path"] as? String,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 1
        }

        return 0
    }

    func guardStatusLabel(outcome: PreventionPolicyOutcome) -> String {
        switch outcome {
        case .pass:
            return "clear"
        case .warn:
            return "warn"
        case .block:
            return "block"
        }
    }

    func executeToolAndCaptureResultWithWatchdog(
        tool: AITool,
        toolCall: AIToolCall,
        mergedArguments: [String: Any],
        conversationId: String?,
        targetFile: String?,
        onProgress: @MainActor @Sendable @escaping (ChatMessage) -> Void,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            let toolTask = Task {
                try await self.executeToolAndCaptureResult(
                    ExecuteToolAndCaptureRequest(
                        tool: tool,
                        toolCall: toolCall,
                        mergedArguments: mergedArguments,
                        conversationId: conversationId,
                        targetFile: targetFile,
                        onProgress: onProgress
                    )
                )
            }

            group.addTask {
                try await toolTask.value
            }

            group.addTask {
                let timeoutSecondsInt = Int(timeoutSeconds)

                while true {
                    let (isExpired, isCancelled) = await MainActor.run {
                        let center = ToolTimeoutCenter.shared
                        return (
                            center.isExpired(toolCallId: toolCall.id),
                            center.isCancelled(toolCallId: toolCall.id)
                        )
                    }
                    // Expiry takes precedence: a deadline that passed without
                    // progress is a TIMEOUT (with recovery guidance), not a
                    // user cancellation.
                    if isExpired {
                        toolTask.cancel()
                        throw ToolExecutionTimedOutError(timeoutSeconds: timeoutSecondsInt)
                    }
                    if isCancelled {
                        toolTask.cancel()
                        throw ToolExecutionCancelledError()
                    }

                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            let first = try await group.next() ?? ""
            group.cancelAll()
            return first
        }
    }

    func makeToolNotFoundMessage(
        _ request: ExecuteToolCallRequest
    ) -> ChatMessage {
        let availableToolNames = request.availableTools.map(\.name).sorted()
        let availableToolsSummary = availableToolNames.isEmpty
            ? "none"
            : availableToolNames.joined(separator: ", ")
        return Self.makeToolExecutionMessage(
            content: "Tool not found in current turn",
            context: ToolExecutionMessageContext(
                toolName: request.toolCall.name,
                status: .failed,
                targetFile: request.targetFile,
                toolCallId: request.toolCall.id,
                preview: nil,
                argumentKeys: Array(request.toolCall.arguments.keys).sorted(),
                argumentPreview: Self.argumentPreview(for: request.toolCall.arguments),
                recoveryHint: "Available tools in this turn: \(availableToolsSummary). Choose one of those tools before retrying.",
                params: Self.normalizedToolParams(request.toolCall.arguments)
            )
        )
    }

    nonisolated static func enrichError(
        _ error: Error,
        toolName: String,
        arguments: [String: Any],
        originalArguments: [String: Any],
        targetFile: String?
    ) -> Error {
        if error is ToolExecutionContextError {
            return error
        }

        let sourceArguments = arguments.isEmpty ? originalArguments : arguments
        let argumentKeys = Array(sourceArguments.keys).sorted()
        let invocationPreview = buildInvocationPreview(
            toolName: toolName,
            targetFile: targetFile,
            arguments: sourceArguments
        )
        let argumentPreview = invocationPreview ?? argumentPreview(for: sourceArguments)
        let recoveryHint = recoveryHintForError(error)

        return ToolExecutionContextError(
            underlying: error,
            argumentKeys: argumentKeys,
            argumentPreview: argumentPreview,
            recoveryHint: recoveryHint
        )
    }

    nonisolated static func argumentPreview(for arguments: [String: Any]) -> String? {
        guard !arguments.isEmpty else { return nil }
        let filtered = arguments.filter { key, _ in
            !key.hasPrefix("_")
        }
        guard !filtered.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(filtered),
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.count > 1200 {
            text = String(text.prefix(1200)) + "\n…"
        }
        return text
    }

    nonisolated static func recoveryHintForError(_ error: Error) -> String? {
        let text = error.localizedDescription.lowercased()
        if text.contains("missing") || text.contains("required") || text.contains("argument") {
            return "Retry with corrected arguments. Ensure all required fields are present and non-empty."
        }
        if text.contains("file not found") || text.contains("no such file") {
            return "Discover the correct path first, then retry the tool call with that exact path."
        }
        if text.contains("permission denied") || text.contains("not permitted") {
            return "Choose a writable target path and avoid protected/system directories."
        }
        if text.contains("timed out") || text.contains("cancelled") || text.contains("canceled") {
            return "Use a finite, non-interactive command or a smaller scoped operation before retrying."
        }
        return "Change parameters or strategy before retrying this tool call."
    }
}
