import Foundation
import Combine

/// Central subscriber for all contextual data events.
/// Writes to `.ide/logs/` NDJSON files — the single persistence path
/// for all data that should survive restart and be available for RAG.
///
/// **Ordering guarantee:** EventBus dispatches on the main queue, so the
/// subscription closures below run serially; each event is yielded into a
/// single `AsyncStream` consumed by exactly one task. Emission order equals
/// append order per file — no fire-and-forget tasks racing each other.
public final class LogCoordinator: @unchecked Sendable {
    enum LogEntry {
        case context(ContextLogEvent)
        case toolResult(ToolResultEvent)
    }

    private let projectRoot: URL
    private let eventBus: EventBusProtocol
    private var bag: Set<AnyCancellable> = []
    private var entries: AsyncStream<LogEntry>.Continuation?
    private var consumer: Task<Void, Never>?

    public init(projectRoot: URL, eventBus: EventBusProtocol) {
        self.projectRoot = projectRoot
        self.eventBus = eventBus
    }

    deinit {
        entries?.finish()
        consumer?.cancel()
    }

    public func start() {
        var continuation: AsyncStream<LogEntry>.Continuation!
        let stream = AsyncStream<LogEntry>(bufferingPolicy: .unbounded) { continuation = $0 }
        entries = continuation

        let root = projectRoot
        consumer = Task {
            for await entry in stream {
                switch entry {
                case .context(let event):
                    await LogCoordinator.writeContextLog(event, projectRoot: root)
                case .toolResult(let event):
                    await LogCoordinator.writeToolResult(event, projectRoot: root)
                }
            }
        }

        eventBus.subscribe(to: ContextLogEvent.self) { [weak self] event in
            self?.entries?.yield(.context(event))
        }.store(in: &bag)
        eventBus.subscribe(to: ToolResultEvent.self) { [weak self] event in
            self?.entries?.yield(.toolResult(event))
        }.store(in: &bag)
    }

    /// Stops consumption and releases the subscription bag (test runtimes).
    public func stop() {
        entries?.finish()
        entries = nil
        consumer?.cancel()
        consumer = nil
        bag.removeAll()
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
        do {
            let json = try JSONEncoder().encode(convEvent)
            var line = Data(json)
            line.append(Data("\n".utf8))
            guard let convId = event.conversationId else { return }
            let convDir = ConversationScopedNDJSONStore.projectConversationDirectory(
                projectRoot: projectRoot,
                conversationId: convId
            )
            await NDJSONAppendStore.shared.append(line, to: convDir.appendingPathComponent("conversation.ndjson"))
        } catch {
            await AppLogger.shared.error(
                category: .conversation,
                message: "LogCoordinator context encode failed: \(error.localizedDescription)"
            )
        }
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

        let execDir = ConversationScopedNDJSONStore.projectConversationDirectory(
            projectRoot: projectRoot,
            conversationId: convId
        )

        do {
            let json = try JSONEncoder().encode(execEvent)
            var line = Data(json)
            line.append(Data("\n".utf8))
            await NDJSONAppendStore.shared.append(line, to: execDir.appendingPathComponent("executions.ndjson"))
        } catch {
            await AppLogger.shared.error(
                category: .tool,
                message: "LogCoordinator execution encode failed: \(error.localizedDescription)"
            )
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
        do {
            let json = try JSONEncoder().encode(convEvent)
            var line = Data(json)
            line.append(Data("\n".utf8))
            await NDJSONAppendStore.shared.append(line, to: execDir.appendingPathComponent("conversation.ndjson"))
        } catch {
            await AppLogger.shared.error(
                category: .conversation,
                message: "LogCoordinator tool-result encode failed: \(error.localizedDescription)"
            )
        }
    }
}
