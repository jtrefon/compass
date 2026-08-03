import Foundation

extension AIToolExecutor {
    func logToolExecuteStart(
        conversationId: String?,
        toolCall: AIToolCall,
        targetFile: String?
    ) async {
        eventBus?.publish(ToolResultEvent(
            conversationId: conversationId,
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            type: "execute_start",
            input: nil,
            output: nil,
            duration: nil,
            metadata: ["targetPath": targetFile ?? ""]
        ))



        await AIToolTraceLogger.shared.log(type: "tool.execute_start", data: [
            "tool": toolCall.name,
            "toolCallId": toolCall.id,
            "targetPath": targetFile as Any,
            "argumentKeys": Array(toolCall.arguments.keys).sorted()
        ])
    }

    func logToolExecuteSuccess(conversationId: String?, toolCall: AIToolCall, resultLength: Int) async {
        eventBus?.publish(ToolResultEvent(
            conversationId: conversationId,
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            type: "execute_success",
            input: nil,
            output: nil,
            duration: nil,
            metadata: ["resultLength": String(resultLength)]
        ))



        await AIToolTraceLogger.shared.log(type: "tool.execute_success", data: [
            "tool": toolCall.name,
            "toolCallId": toolCall.id,
            "resultLength": resultLength
        ])
    }

    func logToolExecuteError(conversationId: String?, toolCall: AIToolCall, error: Error) async {
        eventBus?.publish(ToolResultEvent(
            conversationId: conversationId,
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            type: "execute_error",
            input: nil,
            output: error.localizedDescription,
            duration: nil,
            metadata: [:]
        ))



        await AIToolTraceLogger.shared.log(type: "tool.execute_error", data: [
            "tool": toolCall.name,
            "toolCallId": toolCall.id,
            "error": error.localizedDescription
        ])
    }

    func logToolNotFound(conversationId: String?, toolCall: AIToolCall) async {
        eventBus?.publish(ToolResultEvent(
            conversationId: conversationId,
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            type: "not_found",
            input: nil,
            output: nil,
            duration: nil,
            metadata: [:]
        ))


        await AIToolTraceLogger.shared.log(type: "tool.not_found", data: [
            "tool": toolCall.name,
            "toolCallId": toolCall.id
        ])
    }

    nonisolated static func formatError(_ error: Error, toolName: String) -> String {
        if let contextError = error as? ToolExecutionContextError {
            let base = formatError(contextError.underlying, toolName: toolName)
            var lines: [String] = [base]
            if !contextError.argumentKeys.isEmpty {
                lines.append("")
                lines.append("Argument keys seen: \(contextError.argumentKeys.joined(separator: ", "))")
            }
            if let argumentPreview = contextError.argumentPreview,
               !argumentPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                lines.append("Invocation context:")
                lines.append(argumentPreview)
            }
            if let recoveryHint = contextError.recoveryHint,
               !recoveryHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                lines.append("Recovery hint: \(recoveryHint)")
            }
            return lines.joined(separator: "\n")
        }

        if let timeoutError = error as? ToolExecutionTimedOutError {
            return [
                "Error: Tool execution timed out after \(timeoutError.timeoutSeconds)s.",
                "",
                "IMPORTANT: This tool was terminated for safety to prevent the agent from getting stuck.",
                "This usually means the command/tool did not return control (e.g. started a long-running process, waited for user input, or tailed logs).",
                "",
                "Recovery instructions (do NOT repeat the same call unchanged):",
                "- Use a different approach that completes quickly or produces incremental output.",
                "- Avoid non-terminating commands (dev servers/watchers, \"tail -f\", interactive prompts).",
                "- Prefer non-interactive flags (e.g. --yes, --no-prompt, --non-interactive) and bounded output (e.g. head, sed, grep with limits).",
                "- For npm operations (install, build, create vite), you MUST add \"timeout_seconds\": 600 or higher.",
                "- If re-running a shell command, make it explicitly finite (e.g. add a max count, filter scope, or only run the build/test target you need).",
                "- Example: {\"command\": \"npm install\", \"timeout_seconds\": 600}"
            ].joined(separator: "\n")
        }

        if error is ToolExecutionCancelledError {
            return [
                "Error: Tool execution cancelled.",
                "",
                "IMPORTANT: The tool was stopped intentionally (user action or protective cancellation).",
                "Assume the previous approach risked hanging or was no longer desired.",
                "",
                "Recovery instructions (do NOT repeat the same call unchanged):",
                "- Choose a safer, non-blocking alternative that returns control.",
                "- If the task requires execution, prefer short commands that terminate (build/test/format), not long-running servers/watchers."
            ].joined(separator: "\n")
        }
        
        // Check for missing argument errors
        let errorMessage = error.localizedDescription.lowercased()
        if errorMessage.contains("missing") || errorMessage.contains("required") || errorMessage.contains("argument") {
            return formatMissingArgumentError(error: error, toolName: toolName)
        }

        if toolName == "read" || toolName == "index_read_file" {
            let msg = error.localizedDescription
            if msg.lowercased().hasPrefix("file not found") {
                return "Error: \(msg)\n\nHint: do not guess filenames. " +
                    "First use glob(query: \"RegistrationPage\") or ls(query: \"registration-app/src\") " +
                    "to discover the correct path, then call read with that exact path."
            }
        }
        return "Error: \(error.localizedDescription)"
    }
    
    nonisolated private static func formatMissingArgumentError(error: Error, toolName: String) -> String {
        let errorMsg = error.localizedDescription
        
        // Provide specific guidance based on the tool and missing argument
        switch toolName {
        case "write", "write_files":
            return [
                "Error: \(errorMsg)",
                "",
                "The write tool requires a 'path' and 'content' argument, or 'files' for multi-file writes.",
                "Each file object should have:",
                "  - 'path': The relative path of the file (e.g., 'src/App.js')",
                "  - 'content': The file content as a string",
                "",
                "Example correct call:",
                "{\"path\": \"src/App.js\", \"content\": \"...\"}",
                "or {\"files\": [{\"path\": \"src/App.js\", \"content\": \"...\"}]}",
                "",
                "Common mistakes:",
                "- Passing 'content' instead of 'files' for multi-file writes",
                "- Missing the 'path' or 'content' fields in each file object"
            ].joined(separator: "\n")
            
        case "write_file", "create_file":
            return [
                "Error: \(errorMsg)",
                "",
                "The \(toolName) tool requires:",
                "  - 'path': The relative path of the file to write",
                "  - 'content': The file content as a string",
                "",
                "Example correct call:",
                "{\"path\": \"src/App.js\", \"content\": \"...\"}"
            ].joined(separator: "\n")
            
        case "bash", "run_command":
            return [
                "Error: \(errorMsg)",
                "",
                "The bash tool is session-based.",
                "",
                "Start a command:",
                "  - 'action': 'start'",
                "  - 'command': The shell command to execute",
                "  - 'working_directory': Optional working directory",
                "  - 'wait_seconds': Optional short wait window before control returns",
                "",
                "Continue or control a running command:",
                "  - 'action': 'wait' | 'send_input' | 'stop'",
                "  - 'session_id': Required for wait/send_input/stop",
                "  - 'input': Required for send_input",
                "  - 'append_newline': Optional for send_input",
                "",
                "Examples:",
                "{\"action\": \"start\", \"command\": \"npm test\", \"wait_seconds\": 10}",
                "{\"action\": \"wait\", \"session_id\": \"...\", \"wait_seconds\": 30}",
                "{\"action\": \"send_input\", \"session_id\": \"...\", \"input\": \"y\", \"append_newline\": true, \"wait_seconds\": 10}",
                "{\"action\": \"stop\", \"session_id\": \"...\"}"
            ].joined(separator: "\n")
            
        case "edit", "replace_in_file":
            return [
                "Error: \(errorMsg)",
                "",
                "The edit tool requires:",
                "  - 'path': The file path to modify",
                "  - 'old_text': The exact text to find and replace",
                "  - 'new_text': The replacement text",
                "",
                "Example correct call:",
                "{\"path\": \"src/App.js\", \"old_text\": \"const a = 1\", \"new_text\": \"const a = 2\"}"
            ].joined(separator: "\n")
            
        default:
            return [
                "Error: \(errorMsg)",
                "",
                "The tool call is missing required arguments. Please check the tool schema",
                "and ensure all required fields are provided with correct types.",
                "",
                "Review the tool definition to see required vs optional arguments."
            ].joined(separator: "\n")
        }
    }
}
