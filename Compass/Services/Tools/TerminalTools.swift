//
//  TerminalTools.swift
//  Compass
//
//  Created by AI Assistant on 21/12/2025.
//

import Foundation
import Darwin

private final class RunCommandOutputBuffer: @unchecked Sendable {
    struct Snapshot {
        let version: Int
        let lastAppendAt: Date?
    }

    private let lock = NSLock()
    private var fullData = Data()
    private var pendingDelta = Data()
    private var version: Int = 0
    private var lastAppendAt: Date?
    private let maxFullBytes: Int
    private let maxDeltaBytes: Int

    init(maxFullBytes: Int = 64 * 1024, maxDeltaBytes: Int = 32 * 1024) {
        self.maxFullBytes = maxFullBytes
        self.maxDeltaBytes = maxDeltaBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        version += 1
        lastAppendAt = Date()

        if chunk.count >= maxFullBytes {
            fullData = Data(chunk.suffix(maxFullBytes))
        } else {
            fullData.append(chunk)
            if fullData.count > maxFullBytes {
                fullData.removeFirst(fullData.count - maxFullBytes)
            }
        }

        if chunk.count >= maxDeltaBytes {
            pendingDelta = Data(chunk.suffix(maxDeltaBytes))
        } else {
            pendingDelta.append(chunk)
            if pendingDelta.count > maxDeltaBytes {
                pendingDelta.removeFirst(pendingDelta.count - maxDeltaBytes)
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(version: version, lastAppendAt: lastAppendAt)
    }

    func consumeDeltaString() -> String {
        lock.lock()
        defer { lock.unlock() }
        defer { pendingDelta.removeAll(keepingCapacity: true) }
        return String(data: pendingDelta, encoding: .utf8) ?? ""
    }

    func fullOutputTailString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: fullData, encoding: .utf8) ?? ""
    }
}

private final class RunCommandSession: @unchecked Sendable {
    let id: String
    let command: String
    let workingDirectory: URL
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe
    let outputBuffer: RunCommandOutputBuffer
    let createdAt: Date
    var onOutput: (@Sendable (Data) -> Void)?

    init(
        id: String,
        command: String,
        workingDirectory: URL,
        process: Process,
        inputPipe: Pipe,
        outputPipe: Pipe,
        outputBuffer: RunCommandOutputBuffer,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.outputBuffer = outputBuffer
        self.createdAt = Date()
        self.onOutput = onOutput
    }

    func sendInput(_ text: String) {
        guard process.isRunning else { return }
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        inputPipe.fileHandleForWriting.write(data)
    }
}

private actor RunCommandSessionStore {
    struct Observation {
        let status: String
        let reason: String
        let exitCode: Int32?
        let sessionId: String?
        let command: String
        let workingDirectory: String
        let outputDelta: String
        let outputTail: String
        let suggestedWaitSeconds: Int?
    }

    static let shared = RunCommandSessionStore()

    private var sessions: [String: RunCommandSession] = [:]

    private let dangerousCommandPatterns: [String] = [
        "rm\\s+(-[^\\s]*\\s+)?/\\s*-[rf]",
        ":\\s*\\(\\)\\s*\\{",
        "dd\\s+if=",
        "mkfs\\.",
        "fdisk",
        "shutdown\\b",
        "reboot\\b",
        "halt\\b",
        "poweroff\\b",
        "init\\s+0",
        "chmod\\s+-R?\\s*0{3,4}\\s+/",
        "mv\\s+/\\s+/dev/null",
        "chown\\s+-R?\\s+[^:]+:[^:]+\\s+/",
    ]

    private func validateCommand(_ command: String) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.aiServiceError("Cannot run an empty command.")
        }
        for pattern in dangerousCommandPatterns {
            if trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                throw AppError.aiServiceError(
                    "Command blocked: the requested command contains a destructive pattern. " +
                    "If this is a legitimate use case on a test environment, use a more targeted command."
                )
            }
        }
    }

    func start(
        command: String,
        workingDirectory: URL,
        environment: [String: String],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> RunCommandSession {
        try validateCommand(command)

        let sessionId = UUID().uuidString
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let outputBuffer = RunCommandOutputBuffer()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment
        process.arguments = ["-lc", command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.currentDirectoryURL = workingDirectory

        let session = RunCommandSession(
            id: sessionId,
            command: command,
            workingDirectory: workingDirectory,
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            outputBuffer: outputBuffer,
            onOutput: { data in
                if let str = String(data: data, encoding: .utf8) {
                    onProgress?(str)
                }
            }
        )

        outputPipe.fileHandleForReading.readabilityHandler = { [weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            session?.outputBuffer.append(data)
            session?.onOutput?(data)
        }

        sessions[sessionId] = session
        do {
            try process.run()
        } catch {
            sessions[sessionId] = nil
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        return session
    }

    func observation(
        for sessionId: String,
        waitSeconds: TimeInterval,
        reasonWhenWaitingExpires: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Observation {
        guard let session = sessions[sessionId] else {
            throw AppError.aiServiceError("Unknown run_command session_id '\(sessionId)'. Start a new command instead.")
        }

        // Update onProgress handler for the session
        if let onProgress = onProgress {
            session.onOutput = { data in
                guard let str = String(data: data, encoding: .utf8) else { return }
                onProgress(str)
            }
        }

        let observation = await observe(session: session, waitSeconds: waitSeconds, reasonWhenWaitingExpires: reasonWhenWaitingExpires)
        if observation.status != "running" {
            removeSession(id: session.id)
        }
        return observation
    }

    func sendInput(
        sessionId: String,
        input: String,
        appendNewline: Bool,
        waitSeconds: TimeInterval,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Observation {
        guard let session = sessions[sessionId] else {
            throw AppError.aiServiceError("Unknown run_command session_id '\(sessionId)'.")
        }

        // Update onProgress handler for the session
        if let onProgress = onProgress {
            session.onOutput = { data in
                guard let str = String(data: data, encoding: .utf8) else { return }
                onProgress(str)
            }
        }

        let payload = appendNewline ? input + "\n" : input
        session.sendInput(payload)
        let observation = await observe(session: session, waitSeconds: waitSeconds, reasonWhenWaitingExpires: "input_wait_elapsed")
        if observation.status != "running" {
            removeSession(id: session.id)
        }
        return observation
    }

    func stop(sessionId: String, signal: String? = nil) async throws -> Observation {
        guard let session = sessions[sessionId] else {
            throw AppError.aiServiceError("Unknown run_command session_id '\(sessionId)'.")
        }

        if let signal = signal {
            await sendSignal(session: session, signalName: signal)
        } else {
            await terminate(session: session)
        }

        let observation = makeObservation(
            session: session,
            status: "stopped",
            reason: "stopped",
            exitCode: session.process.terminationStatus,
            suggestedWaitSeconds: nil
        )
        removeSession(id: session.id)
        return observation
    }

    private func sendSignal(session: RunCommandSession, signalName: String) async {
        guard session.process.isRunning else { return }

        let signalMap: [String: Int32] = [
            "SIGINT": SIGINT,
            "SIGTERM": SIGTERM,
            "SIGKILL": SIGKILL,
            "SIGHUP": SIGHUP,
            "SIGQUIT": SIGQUIT,
            "SIGUSR1": SIGUSR1,
            "SIGUSR2": SIGUSR2
        ]

        let sig = signalMap[signalName.uppercased()] ?? SIGTERM
        kill(session.process.processIdentifier, sig)
        
        // Give it a moment to react
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func observe(
        session: RunCommandSession,
        waitSeconds: TimeInterval,
        reasonWhenWaitingExpires: String
    ) async -> Observation {
        let baseline = session.outputBuffer.snapshot()
        let deadline = Date().addingTimeInterval(waitSeconds)
        let settleInterval: TimeInterval = 0.25

        while Date() < deadline {
            // Timeout/cancel from the executor must kill the underlying
            // process — previously the observe loop ignored Task cancellation
            // and the command kept running until waitSeconds elapsed.
            if Task.isCancelled {
                await terminate(session: session)
                return makeObservation(
                    session: session,
                    status: "exited",
                    reason: "cancelled",
                    exitCode: session.process.terminationStatus,
                    suggestedWaitSeconds: nil
                )
            }
            if !session.process.isRunning {
                return makeObservation(
                    session: session,
                    status: "exited",
                    reason: "exited",
                    exitCode: session.process.terminationStatus,
                    suggestedWaitSeconds: nil
                )
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let status = session.process.isRunning ? "running" : "exited"
        let exitCode = status == "running" ? nil : session.process.terminationStatus
        return makeObservation(
            session: session,
            status: status,
            reason: status == "running" ? reasonWhenWaitingExpires : "exited",
            exitCode: exitCode,
            suggestedWaitSeconds: status == "running" ? 30 : nil
        )
    }

    private func makeObservation(
        session: RunCommandSession,
        status: String,
        reason: String,
        exitCode: Int32?,
        suggestedWaitSeconds: Int?
    ) -> Observation {
        Observation(
            status: status,
            reason: reason,
            exitCode: exitCode,
            sessionId: status == "running" ? session.id : nil,
            command: session.command,
            workingDirectory: session.workingDirectory.path,
            outputDelta: session.outputBuffer.consumeDeltaString(),
            outputTail: session.outputBuffer.fullOutputTailString(),
            suggestedWaitSeconds: suggestedWaitSeconds
        )
    }

    private func terminate(session: RunCommandSession) async {
        if session.process.isRunning {
            kill(session.process.processIdentifier, SIGINT)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        if session.process.isRunning {
            session.process.terminate()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        if session.process.isRunning {
            kill(session.process.processIdentifier, SIGKILL)
        }
    }

    private func removeSession(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.outputPipe.fileHandleForReading.readabilityHandler = nil
        try? session.inputPipe.fileHandleForWriting.close()
        try? session.outputPipe.fileHandleForReading.close()
    }
}

/// Run a shell command.
struct RunCommandTool: AITool {
    private enum Action: String {
        case start
        case wait
        case sendInput = "send_input"
        case stop
    }

    private struct Request {
        let action: Action
        let command: String?
        let sessionId: String?
        let input: String?
        let appendNewline: Bool
        let waitSeconds: TimeInterval
        let workingDirectoryURL: URL?
    }

    let name = "bash"
    let description = "Run builds, tests, package management, git operations, and long-running processes. For codebase exploration and file search, use `search` or `glob` instead."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "description": "start | wait | send_input | stop. Defaults to start."
                ],
                "command": [
                    "type": "string",
                    "description": "Shell command to execute. Required for action=start."
                ],
                "working_directory": [
                    "type": "string",
                    "description": "Directory to run the command in. Optional for action=start."
                ],
                "session_id": [
                    "type": "string",
                    "description": "Existing run_command session id. Required for wait, send_input, and stop."
                ],
                "input": [
                    "type": "string",
                    "description": "Text to send to the process stdin for action=send_input."
                ],
                "append_newline": [
                    "type": "boolean",
                    "description": "Append a newline after input when action=send_input. Defaults to false."
                ],
                "signal": [
                    "type": "string",
                    "description": "Optional signal name (e.g. SIGINT, SIGKILL) for action=stop."
                ],
                "wait_seconds": [
                    "type": "number",
                    "description": "How long to wait for output or completion before returning control. Defaults: start uses the CLI setting (15s fallback), wait/send_input use 30s."
                ],
                "timeout_seconds": [
                    "type": "number",
                    "description": "Deprecated alias for wait_seconds."
                ]
            ]
        ]
    }

    let projectRoot: URL
    let pathValidator: PathValidator

    func execute(arguments: ToolArguments) async throws -> String {
        try await executeImpl(arguments: arguments.raw, onProgress: nil)
    }

    func execute(
        arguments: ToolArguments,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await executeImpl(arguments: arguments.raw, onProgress: onProgress)
    }

    private func executeImpl(
        arguments: [String: Any],
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let request = try resolveRequest(arguments: arguments)
        let environment = ProcessInfo.processInfo.environment

        switch request.action {
        case .start:
            guard let command = request.command else {
                throw AppError.aiServiceError("Missing 'command' argument for run_command action=start")
            }
            // Redirect codebase-exploration commands to the dedicated tools
            // (§14 — audit: 49 of 79 tool calls in one session were bash-as-exploration)
            if isExploratoryCommand(command) {
                throw AppError.aiServiceError(
                    "This command is codebase exploration. Use dedicated tools instead:\n" +
                    "  `find`/`grep`/`rg` → use `search` (content) or `glob` (filenames)\n" +
                    "  `ls -R`            → use `ls` (directories) or `glob` (recursive file names)\n" +
                    "  `tree`/`locate`    → use `ls` (directories)\n" +
                    "These tools are faster and return structured results. The original command was: `\(command)`"
                )
            }
            let workingDirectoryURL = request.workingDirectoryURL ?? projectRoot
            let session = try await RunCommandSessionStore.shared.start(
                command: command,
                workingDirectory: workingDirectoryURL,
                environment: environment,
                onProgress: onProgress
            )
            let observation = try await RunCommandSessionStore.shared.observation(
                for: session.id,
                waitSeconds: request.waitSeconds,
                reasonWhenWaitingExpires: "wait_elapsed",
                onProgress: onProgress
            )
            return encodeObservation(observation)

        case .wait:
            guard let sessionId = request.sessionId else {
                throw AppError.aiServiceError("Missing 'session_id' argument for run_command action=wait")
            }
            let observation = try await RunCommandSessionStore.shared.observation(
                for: sessionId,
                waitSeconds: request.waitSeconds,
                reasonWhenWaitingExpires: "wait_elapsed",
                onProgress: onProgress
            )
            return encodeObservation(observation)

        case .sendInput:
            guard let sessionId = request.sessionId else {
                throw AppError.aiServiceError("Missing 'session_id' argument for run_command action=send_input")
            }
            let input = request.input ?? ""
            let observation = try await RunCommandSessionStore.shared.sendInput(
                sessionId: sessionId,
                input: input,
                appendNewline: request.appendNewline,
                waitSeconds: request.waitSeconds,
                onProgress: onProgress
            )
            return encodeObservation(observation)

        case .stop:
            guard let sessionId = request.sessionId else {
                throw AppError.aiServiceError("Missing 'session_id' argument for run_command action=stop")
            }
            let signal = (arguments["signal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let observation = try await RunCommandSessionStore.shared.stop(
                sessionId: sessionId,
                signal: signal?.isEmpty == false ? signal : nil
            )
            return encodeObservation(observation)
        }
    }

    private func resolveRequest(arguments: [String: Any]) throws -> Request {
        let action = Action(rawValue: (arguments["action"] as? String ?? "start").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .start
        let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = (arguments["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendNewline = ToolArgumentCoercion.asBool(arguments["append_newline"]) ?? false
        let waitSeconds = try resolveWaitSeconds(arguments: arguments, action: action)
        let workingDirectoryURL = try resolveWorkingDirectory(arguments: arguments, action: action)

        return Request(
            action: action,
            command: command?.isEmpty == false ? command : nil,
            sessionId: sessionId?.isEmpty == false ? sessionId : nil,
            input: arguments["input"] as? String,
            appendNewline: appendNewline,
            waitSeconds: waitSeconds,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    private func resolveWaitSeconds(arguments: [String: Any], action: Action) throws -> TimeInterval {
        let raw = arguments["wait_seconds"] ?? arguments["timeout_seconds"]
        if let explicit = ToolArgumentCoercion.asDouble(raw) {
            guard (1...600).contains(explicit) else {
                throw AppError.aiServiceError("Invalid wait_seconds for run_command. Must be between 1 and 600.")
            }
            return explicit
        }

        switch action {
        case .start:
            let stored = UserDefaults.standard.double(forKey: AppConstantsStorage.cliTimeoutSecondsKey)
            let fallback = stored == 0 ? 15 : stored
            return max(1, min(600, fallback))
        case .wait, .sendInput:
            return 30
        case .stop:
            return 1
        }
    }

    private func resolveWorkingDirectory(arguments: [String: Any], action: Action) throws -> URL? {
        guard action == .start else { return nil }
        guard let workingDirectoryArg = arguments["working_directory"] as? String,
              !workingDirectoryArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projectRoot
        }
        return try pathValidator.validateAndResolve(workingDirectoryArg)
    }

    /// Redirects codebase-exploration commands (find, grep, rg, ls -R, tree, …) to
    /// the dedicated `search`/`glob`/`ls` tools. This prevents the model from
    /// burning iterations on shell-based file discovery when purpose-built tools
    /// are available (§14 — audit: 49/79 tool calls in one session were bash-as-exploration).
    private func isExploratoryCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exploratoryPatterns = [
            #"^find\s"#,
            #"^rg\s"#,
            #"^grep\s"#,
            #"^ag\s"#,
            #"^fd\s"#,
            #"^locate\s"#,
            #"^tree\b"#,
            #"^git\s+grep"#,
            #"^ls\s.*-[a-zA-Z]*[Rr]"#,
        ]
        return exploratoryPatterns.contains { trimmed.range(of: $0, options: [.regularExpression]) != nil }
    }

    /// Strip leading ./ prefix from each line so the model sees clean relative paths
    private func sanitizeBashOutput(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var s = String(line)
            while s.hasPrefix("./") {
                s = String(s.dropFirst(2))
            }
            return s
        }.joined(separator: "\n")
    }

    private func encodeObservation(_ observation: RunCommandSessionStore.Observation) -> String {
        var lines: [String] = []
        lines.append("Command: \(observation.command)")
        lines.append("Status: \(observation.status)")
        if let exitCode = observation.exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if observation.status == "running" {
            lines.append("")
            if !observation.outputTail.isEmpty {
                lines.append("[output so far]")
                lines.append(sanitizeBashOutput(observation.outputTail))
            }
            if let suggestedWait = observation.suggestedWaitSeconds, suggestedWait > 0 {
                lines.append("")
                lines.append("Use action=wait session_id=\(observation.sessionId ?? "") wait_seconds=\(suggestedWait) to see more output.")
            } else if let sessionId = observation.sessionId {
                lines.append("")
                lines.append("Use action=wait session_id=\(sessionId) to poll for more output.")
            }
        } else {
            if !observation.outputDelta.isEmpty {
                lines.append("")
                lines.append("[new output]")
                lines.append(sanitizeBashOutput(observation.outputDelta))
            }
            if !observation.outputTail.isEmpty {
                lines.append("")
                lines.append("[full output]")
                lines.append(sanitizeBashOutput(observation.outputTail))
            }
            if observation.reason != "exited" {
                lines.append("")
                lines.append("Reason: \(observation.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
