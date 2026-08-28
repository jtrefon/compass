import Foundation

public actor AppLogger {
    public static let shared = AppLogger()

    public struct LogCallContext: @unchecked Sendable {
        public let metadata: [String: Any]?
        public let file: String
        public let function: String
        public let line: Int

        public init(
            metadata: [String: Any]? = nil,
            file: String = #fileID,
            function: String = #function,
            line: Int = #line
        ) {
            self.metadata = metadata
            self.file = file
            self.function = function
            self.line = line
        }
    }

    private let sessionId: String
    private let encoder: JSONEncoder
    private var config: LoggingConfiguration

    // Project-local log file only
    private var projectLogFileURL: URL?

    public init(
        sessionId: String = UUID().uuidString,
        configuration: LoggingConfiguration = LoggingConfiguration()
    ) {
        self.sessionId = sessionId
        self.config = configuration

        let enc = JSONEncoder()
        enc.outputFormatting = []
        self.encoder = enc
        // Note: No fallback to Application Support - logs only go to project directory
    }

    public func setProjectRoot(_ projectRoot: URL) {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let logsDir = ideDir.appendingPathComponent("logs", isDirectory: true)
        self.projectLogFileURL = logsDir.appendingPathComponent("app.ndjson")
    }

    public func currentSessionId() -> String {
        sessionId
    }

    public func log(
        _ level: LogLevel,
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        guard shouldLog(level) else { return }

        let record = LogRecord(
            ts: ISO8601DateFormatter().string(from: Date()),
            session: sessionId,
            level: level,
            category: category,
            message: message,
            metadata: context.metadata?.mapValues { LogValue.from($0) },
            file: context.file,
            function: context.function,
            line: context.line
        )

        write(record: record)

        if config.enableConsole {
            #if DEBUG
            #endif
        }
    }

    public func trace(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(
            .trace,
            category: category,
            message: message,
            context: context
        )
    }

    public func debug(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(
            .debug,
            category: category,
            message: message,
            context: context
        )
    }

    public func info(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(.info, category: category, message: message, context: context)
    }

    public func warning(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(
            .warning,
            category: category,
            message: message,
            context: context
        )
    }

    public func error(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(
            .error,
            category: category,
            message: message,
            context: context
        )
    }

    public func critical(
        category: LogCategory,
        message: String,
        context: LogCallContext = LogCallContext()
    ) {
        log(
            .critical,
            category: category,
            message: message,
            context: context
        )
    }

    private func shouldLog(_ level: LogLevel) -> Bool {
        let rank: [LogLevel: Int] = [
            .trace: 0,
            .debug: 1,
            .info: 2,
            .warning: 3,
            .error: 4,
            .critical: 5
        ]
        return (rank[level] ?? 999) >= (rank[config.minimumLevel] ?? 999)
    }

    private func write(record: LogRecord) {
        guard let projectLogFileURL = projectLogFileURL else { return }
        
        do {
            try ensureDirectoryExists(for: projectLogFileURL)
            let data = try encoder.encode(record)
            var line = Data()
            line.append(data)
            line.append(Data("\n".utf8))

            try append(line: line, to: projectLogFileURL)
        } catch {
            // Silently skip logging errors to avoid impacting app
        }
    }

    private func append(line: Data, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: [.atomic])
        }
    }

    private func ensureDirectoryExists(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }
}
