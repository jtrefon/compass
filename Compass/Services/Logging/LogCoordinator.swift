import Foundation
import Combine

/// Central subscriber for all contextual data events.
/// Writes to `.ide/logs/` NDJSON files — the single persistence path
/// for all data that should survive restart and be available for RAG.
public final class LogCoordinator: @unchecked Sendable {
    private let projectRoot: URL
    private let eventBus: EventBusProtocol
    private let iso = ISO8601DateFormatter()
    private var bag: Set<AnyCancellable> = []

    public init(projectRoot: URL, eventBus: EventBusProtocol) {
        self.projectRoot = projectRoot
        self.eventBus = eventBus
    }

    public func start() {
        let root = projectRoot
        eventBus.subscribe(to: ContextLogEvent.self) { event in
            Task { await LogCoordinator.writeContextLog(event, projectRoot: root) }
        }.store(in: &bag)
        let root2 = projectRoot
        eventBus.subscribe(to: ToolResultEvent.self) { event in
            Task { await LogCoordinator.writeToolResult(event, projectRoot: root2) }
        }.store(in: &bag)
    }

    // MARK: - ContextLogEvent → conversation.ndjson

    static nonisolated func writeContextLog(_ event: ContextLogEvent, projectRoot: URL) async {
        let iso = ISO8601DateFormatter()
        let convEvent = ConversationLogEvent(
            ts: iso.string(from: Date()),
            session: await AppLogger.shared.currentSessionId(),
            conversationId: event.conversationId ?? "unknown",
            type: event.source,
            data: event.metadata.merging(["content": event.content]) { $1 }.mapValues { LogValue.string($0) }
        )
        guard let json = try? JSONEncoder().encode(convEvent) else { return }
        var line = Data(json)
        line.append(Data("\n".utf8))
        guard let convId = event.conversationId else { return }
        let convDir = ConversationScopedNDJSONStore.projectConversationDirectory(
            projectRoot: projectRoot,
            conversationId: convId
        )
        let fileURL = convDir.appendingPathComponent("conversation.ndjson")
        try? NDJSONLogFileWriter.ensureDirectoryExists(for: fileURL)
        try? NDJSONLogFileWriter.append(line: line, to: fileURL)
    }

    // MARK: - ToolResultEvent → executions.ndjson + conversation.ndjson

    static nonisolated func writeToolResult(_ event: ToolResultEvent, projectRoot: URL) async {
        let iso = ISO8601DateFormatter()
        let convId = event.conversationId ?? "unknown"

        let header = ExecutionLogEventHeader(
            ts: iso.string(from: Date()),
            session: await AppLogger.shared.currentSessionId(),
            conversationId: event.conversationId,
            tool: event.toolName
        )
        var execData: [String: LogValue] = event.metadata.reduce(into: [:]) { $0[$1.key] = .string($1.value) }
        if let input = event.input { execData["input"] = .string(input) }
        if let output = event.output { execData["output"] = .string(output) }
        if let duration = event.duration { execData["duration"] = .string(String(format: "%.2f", duration)) }

        let execEvent = ExecutionLogEvent(
            header: header,
            toolCallId: event.toolCallId,
            type: event.type,
            data: execData
        )
        if let json = try? JSONEncoder().encode(execEvent) {
            var line = Data(json)
            line.append(Data("\n".utf8))
            let execDir = ConversationScopedNDJSONStore.projectConversationDirectory(
                projectRoot: projectRoot,
                conversationId: convId
            )
            let execFileURL = execDir.appendingPathComponent("executions.ndjson")
            try? NDJSONLogFileWriter.ensureDirectoryExists(for: execFileURL)
            try? NDJSONLogFileWriter.append(line: line, to: execFileURL)
        }

        var convData: [String: String] = ["tool": event.toolName, "toolCallId": event.toolCallId]
        if let output = event.output { convData["result"] = output }
        if let duration = event.duration { convData["duration"] = String(format: "%.2f", duration) }
        let convEvent = ConversationLogEvent(
            ts: iso.string(from: Date()),
            session: await AppLogger.shared.currentSessionId(),
            conversationId: convId,
            type: "tool.\(event.type)",
            data: convData.mapValues { LogValue.string($0) }
        )
        if let json = try? JSONEncoder().encode(convEvent) {
            var line = Data(json)
            line.append(Data("\n".utf8))
            let convDir = ConversationScopedNDJSONStore.projectConversationDirectory(
                projectRoot: projectRoot,
                conversationId: convId
            )
            let convFileURL = convDir.appendingPathComponent("conversation.ndjson")
            try? NDJSONLogFileWriter.ensureDirectoryExists(for: convFileURL)
            try? NDJSONLogFileWriter.append(line: line, to: convFileURL)
        }
    }
}
