import Foundation

public actor ExecutionLogStore {
    public static let shared = ExecutionLogStore()

    private let iso = ISO8601DateFormatter()

    private var projectRoot: URL?

    public func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    public func append(_ request: ExecutionLogAppendRequest) async {
        let sessionId = await AppLogger.shared.currentSessionId()
        let conversationId = request.context.conversationId ?? "unknown"

        let header = ExecutionLogEventHeader(
            ts: iso.string(from: Date()),
            session: sessionId,
            conversationId: request.context.conversationId,
            tool: request.context.tool
        )
        let event = ExecutionLogEvent(
            header: header,
            toolCallId: request.toolCallId,
            type: request.type,
            data: request.data
        )

        do {
            let json = try JSONEncoder().encode(event)
            var line = Data()
            line.append(json)
            line.append(Data("\n".utf8))

            try ConversationScopedNDJSONStore.appendLine(
                line,
                conversationId: conversationId,
                fileName: "executions.ndjson",
                projectRoot: projectRoot
            )
        } catch {
            await CrashReporter.shared.capture(
                error,
                context: CrashReportContext(operation: "ExecutionLogStore.append"),
                metadata: ["conversationId": conversationId],
                file: #fileID,
                function: #function,
                line: #line
            )
        }
    }
}
