import Foundation

public actor ConversationLogStore {
    public static let shared = ConversationLogStore()

    private let iso = ISO8601DateFormatter()
    private var projectRoot: URL?
    private var eventBus: EventBusProtocol?

    public func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    public func setEventBus(_ bus: EventBusProtocol) {
        self.eventBus = bus
    }

    public func append(
        conversationId: String,
        type: String,
        data: [String: Any]? = nil
    ) async {
        let sessionId = await AppLogger.shared.currentSessionId()
        let event = ConversationLogEvent(
            ts: iso.string(from: Date()),
            session: sessionId,
            conversationId: conversationId,
            type: type,
            data: data?.mapValues { LogValue.from($0) }
        )

        let content = data?["content"] as? String ?? ""
        if !content.isEmpty || type.hasPrefix("tool.") || type.hasPrefix("chat.") {
            let safeMetadata: [String: String] = (data ?? [:]).compactMapValues { value in
                if let str = value as? String { return str }
                if let num = value as? NSNumber { return num.stringValue }
                if let bool = value as? Bool { return bool ? "true" : "false" }
                return nil
            }
            eventBus?.publish(ContextLogEvent(
                conversationId: conversationId,
                source: type,
                content: content,
                metadata: safeMetadata
            ))
        }

        do {
            let json = try JSONEncoder().encode(event)
            var line = Data()
            line.append(json)
            line.append(Data("\n".utf8))

            try ConversationScopedNDJSONStore.appendLine(
                line,
                conversationId: conversationId,
                fileName: "conversation.ndjson",
                projectRoot: projectRoot
            )
        } catch {
            await CrashReporter.shared.capture(
                error,
                context: CrashReportContext(operation: "ConversationLogStore.append"),
                metadata: ["conversationId": conversationId],
                file: #fileID,
                function: #function,
                line: #line
            )
        }
    }
}
