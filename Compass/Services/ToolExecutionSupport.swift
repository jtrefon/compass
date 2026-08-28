import Foundation
import SwiftUI

// swiftlint:disable file_length

// MARK: - Tool trace logger

@MainActor
final class AIToolTraceLogger {
    static let shared = AIToolTraceLogger()

    private var projectRoot: URL?
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.Compass.ai-trace")

    func log(type: String, data: [String: Any]) {
        var payload = data
        payload["type"] = type
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard let line = (try? JSONSerialization.data(withJSONObject: payload)) ?? nil,
              let lineData = line as Data? else { return }
        let logLine = lineData + Data("\n".utf8)
        queue.async { [weak self] in
            guard let self else { return }
            guard let fileHandle = self.fileHandle else { return }
            try? fileHandle.write(contentsOf: logLine)
        }
    }

    func setProjectRoot(_ root: URL) {
        let resolvedRoot = root.appendingPathComponent(".ide", isDirectory: true)
        let logsDir = resolvedRoot.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fileURL = logsDir.appendingPathComponent("ai-trace.ndjson")
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            fileHandle = handle
        } catch {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
        }
        projectRoot = root
    }

    /// Per-session cutoff: truncate ai-trace.ndjson on new session, keep previous as .bak.
    /// Called from SessionManager.startNew / clear (new conversationId). Overwrite is best at this stage
    /// so the live file is always current session only (no sifting through 3 fixed issues' history).
    func startNewSession(conversationId: String) {
        queue.async { [weak self] in
            guard let self, let root = self.projectRoot else { return }
            let logsDir = root.appendingPathComponent(".ide", isDirectory: true).appendingPathComponent("logs", isDirectory: true)
            let fileURL = logsDir.appendingPathComponent("ai-trace.ndjson")
            let bakURL = logsDir.appendingPathComponent("ai-trace.\(conversationId).bak.ndjson")
            // Only rotate if current file has content and is not already for this conversation
            // Check if current file's last session.start is already this conversationId
            if let handle = self.fileHandle {
                try? handle.close()
                self.fileHandle = nil
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = attrs?[.size] as? UInt64 ?? 0
                if size > 1024 { // only rotate if meaningful content (not empty)
                    // If a bak for this conversation already exists, keep it (don't overwrite previous bak)
                    if !FileManager.default.fileExists(atPath: bakURL.path) {
                        try? FileManager.default.moveItem(at: fileURL, to: bakURL)
                    } else {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                } else if size > 0 {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            self.fileHandle = try? FileHandle(forWritingTo: fileURL)
            // Marker so the new file is self-describing
            var payload: [String: Any] = ["type": "session.start", "conversationId": conversationId]
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
            if let line = try? JSONSerialization.data(withJSONObject: payload),
               let handle = self.fileHandle {
                try? handle.write(contentsOf: line + Data("\n".utf8))
            }
        }
    }

    func currentLogFilePath() -> String? {
        guard let projectRoot else { return nil }
        return projectRoot
            .appendingPathComponent(".ide", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ai-trace.ndjson")
            .path
    }
}

@MainActor
final class ToolArgumentResolver {
    private let fileSystemService: FileSystemService
    private var projectRoot: URL
    private let defaultFilePathProvider: (@MainActor () -> String?)?

    init(fileSystemService: FileSystemService, projectRoot: URL, defaultFilePathProvider: (@MainActor () -> String?)?) {
        self.fileSystemService = fileSystemService
        self.projectRoot = projectRoot
        self.defaultFilePathProvider = defaultFilePathProvider
    }
    func updateProjectRoot(_ root: URL) { projectRoot = root }
    func isWriteLikeTool(_ name: String) -> Bool { ToolTaxonomy.mutation.contains(name) }
    func pathKey(for toolCall: AIToolCall) -> String {
        (toolCall.arguments["path"] as? String) ?? toolCall.arguments["targetPath"] as? String ?? ""
    }
    func resolveTargetFile(for toolCall: AIToolCall) -> String? {
        toolCall.arguments["path"] as? String ?? toolCall.arguments["targetPath"] as? String
    }
    func buildMergedArguments(toolCall: AIToolCall, conversationId: String?) async -> [String: Any] {
        var merged = toolCall.arguments
        if let cid = conversationId { merged["_conversation_id"] = cid }
        return merged
    }
}

// MARK: - Tool scheduler (write serialization)

@MainActor
final class ToolScheduler {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Serializes writes to the same `pathKey`: only one write per key runs at a
    /// time; later writes wait until the earlier one completes.
    func runWriteTask<R: Sendable>(pathKey: String, body: () async throws -> R) async throws -> R {
        guard !pathKey.isEmpty else { return try await body() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if held.contains(pathKey) {
                var queue = waiters[pathKey] ?? []
                queue.append(continuation)
                waiters[pathKey] = queue
            } else {
                held.insert(pathKey)
                continuation.resume()
            }
        }
        defer { release(pathKey) }
        return try await body()
    }

    private func release(_ pathKey: String) {
        var queue = waiters[pathKey] ?? []
        if let next = queue.first {
            queue.removeFirst()
            if queue.isEmpty {
                waiters[pathKey] = nil
            } else {
                waiters[pathKey] = queue
            }
            next.resume()
        } else {
            waiters[pathKey] = nil
            held.remove(pathKey)
        }
    }
}

// MARK: - Tool timeout center

@MainActor
final class ToolTimeoutCenter: ObservableObject {
    static let shared = ToolTimeoutCenter()

    @Published var activeToolCallId: String?
    @Published var countdownSeconds: Int?

    private struct ActiveEntry {
        var toolName: String
        var targetFile: String?
        var deadline: Date
        var explicitlyCancelled = false
    }

    private var active: [String: ActiveEntry] = [:]
    private var countdownTask: Task<Void, Never>?

    func begin(toolCallId: String, toolName: String, targetFile: String?, timeoutSeconds: TimeInterval) {
        let effectiveTimeout = max(timeoutSeconds, 1)
        active[toolCallId] = ActiveEntry(
            toolName: toolName,
            targetFile: targetFile,
            deadline: Date().addingTimeInterval(effectiveTimeout)
        )
        if activeToolCallId == nil {
            activeToolCallId = toolCallId
            startCountdown()
        }
    }

    func finish(toolCallId: String) { remove(toolCallId) }
    /// Explicit user/UI cancellation (distinct from deadline expiry).
    func cancel(toolCallId: String) {
        guard var entry = active[toolCallId] else { return }
        entry.explicitlyCancelled = true
        active[toolCallId] = entry
    }

    func clear() {
        active.removeAll()
        stopCountdown()
        activeToolCallId = nil
        countdownSeconds = nil
    }

    /// Deadline passed WITHOUT explicit cancellation. The entry is KEPT —
    /// removing it on expiry raced the watchdog, which then saw no deadline
    /// and let hung tools run forever.
    func isExpired(toolCallId: String) -> Bool {
        guard let entry = active[toolCallId], !entry.explicitlyCancelled else { return false }
        return entry.deadline <= Date()
    }

    /// Explicitly cancelled by the user/UI.
    func isCancelled(toolCallId: String) -> Bool {
        active[toolCallId]?.explicitlyCancelled == true
    }

    func remainingSeconds(toolCallId: String) -> TimeInterval? {
        guard let entry = active[toolCallId] else { return nil }
        return max(0, entry.deadline.timeIntervalSinceNow)
    }

    func cancelActiveToolNow() {
        if let id = activeToolCallId { cancel(toolCallId: id) }
    }

    private func remove(_ toolCallId: String) {
        active.removeValue(forKey: toolCallId)
        guard activeToolCallId == toolCallId else { return }
        if let nextId = active.keys.first {
            activeToolCallId = nextId
            updateCountdown()
        } else {
            activeToolCallId = nil
            countdownSeconds = nil
            stopCountdown()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.updateCountdown()
            }
        }
    }

    private func updateCountdown() {
        guard let id = activeToolCallId, let entry = active[id] else {
            countdownSeconds = nil
            return
        }
        let remaining = entry.deadline.timeIntervalSinceNow
        countdownSeconds = max(0, Int(remaining.rounded(.up)))
        // Never remove the entry here — expiry is decided by the watchdog.
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }
}

// MARK: - Tool execution coordinator

@MainActor
final class ToolExecutionCoordinator {
    private let executor: AIToolExecutor
    private var cancelledToolCallIdsProvider: @Sendable () -> Set<String>

    init(
        executor: AIToolExecutor,
        cancelledToolCallIds: @escaping @Sendable () -> Set<String> = { [] }
    ) {
        self.executor = executor
        self.cancelledToolCallIdsProvider = cancelledToolCallIds
    }

    func setCancellationProvider(_ provider: @escaping @Sendable () -> Set<String>) {
        cancelledToolCallIdsProvider = provider
    }

    func executeToolCalls(
        _ calls: [AIToolCall], availableTools: [AITool],
        conversationId: String,
        onProgressMessage: (@MainActor (ChatMessage) -> Void)? = nil
    ) async -> [ChatMessage] {
        var results: [ChatMessage] = []
        for call in calls {
            // Stop (task cancellation) aborts the remaining batch — without
            // this, queued tools kept running and writing files after Stop.
            if Task.isCancelled { break }
            if cancelledToolCallIdsProvider().contains(call.id) {
                let tctx = ChatMessageToolContext(
                    toolName: call.name,
                    toolStatus: .failed,
                    target: ToolInvocationTarget(toolCallId: call.id)
                )
                let msg = ChatMessage(
                    role: .tool,
                    content: "Tool execution cancelled by user.",
                    tool: tctx
                )
                results.append(msg)
                onProgressMessage?(msg)
                continue
            }
            let msg = await executor.executeToolCall(
                AIToolExecutor.ExecuteToolCallRequest(
                    toolCall: call,
                    availableTools: availableTools,
                    conversationId: conversationId,
                    onProgress: { progress in
                        onProgressMessage?(progress)
                    },
                    targetFile: executor.resolveTargetFile(for: call)
                )
            )
            results.append(msg)
            onProgressMessage?(msg)
        }
        return results
    }
}

// MARK: - Tool timeout circuit breaker

actor ToolTimeoutCircuitBreaker {
    static let shared = ToolTimeoutCircuitBreaker()

    private struct Entry {
        var count: Int
        var lastTrippedAt: Date?
        var lastFailureAt: Date?
    }

    private var entries: [String: Entry] = [:]
    private let threshold: Int
    private let cooldown: TimeInterval
    private let window: TimeInterval

    init(
        threshold: Int = ProcessInfo.processInfo.environment["COMPASS_CIRCUIT_FAILURE_THRESHOLD"].flatMap(Int.init) ?? 3,
        cooldown: TimeInterval = ProcessInfo.processInfo.environment["COMPASS_CIRCUIT_COOLDOWN_SEC"].flatMap(TimeInterval.init) ?? 300,
        window: TimeInterval = 600
    ) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.window = window
    }

    func reset(normalizedKey: String) {
        entries[normalizedKey]?.count = 0
    }

    func record(normalizedKey: String) -> (tripped: Bool, count: Int) {
        let now = Date()
        var entry = entries[normalizedKey] ?? Entry(count: 0, lastTrippedAt: nil, lastFailureAt: nil)

        if let lastTripped = entry.lastTrippedAt, now.timeIntervalSince(lastTripped) < cooldown {
            entries[normalizedKey] = entry
            return (true, entry.count)
        }

        if let lastFailureAt = entry.lastFailureAt, now.timeIntervalSince(lastFailureAt) > window {
            entry.count = 0
        }

        entry.count += 1
        let tripped = entry.count >= threshold
        if tripped {
            entry.lastTrippedAt = now
        }
        entry.lastFailureAt = now
        entries[normalizedKey] = entry
        return (tripped, entry.count)
    }
}
