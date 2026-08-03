import Foundation

public actor CrashReporter: CrashReporting {
    public static let shared = CrashReporter()

    private let sessionId: String
    private let iso = ISO8601DateFormatter()
    private let encoder: JSONEncoder

    // Project-local crash log only
    private var projectCrashLogFileURL: URL?

    public init(sessionId: String = UUID().uuidString) {
        self.sessionId = sessionId

        let enc = JSONEncoder()
        enc.outputFormatting = []
        self.encoder = enc
        // Note: No fallback to Application Support - crashes only logged to project directory
    }

    public func setProjectRoot(_ root: URL) async {
        let ideDir = root.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let logsDir = ideDir.appendingPathComponent("logs", isDirectory: true)
        self.projectCrashLogFileURL = logsDir.appendingPathComponent("crash.ndjson")
    }

    public func capture(
        _ error: Error,
        context: CrashReportContext,
        metadata: [String: String] = [:],
        file: String,
        function: String,
        line: Int
    ) async {
        let event = CrashReportEvent(
            timestamp: iso.string(from: Date()),
            session: sessionId,
            operation: context.operation,
            errorType: String(reflecting: type(of: error)),
            errorDescription: error.localizedDescription,
            file: file,
            function: function,
            line: line,
            metadata: metadata
        )

        await append(event)
    }

    private func append(_ event: CrashReportEvent) async {
        guard let projectCrashLogFileURL = projectCrashLogFileURL else { return }
        
        do {
            let data = try encoder.encode(event)
            var lineData = Data()
            lineData.append(data)
            lineData.append(Data("\n".utf8))

            try ensureDirectoryExists(for: projectCrashLogFileURL)
            try append(line: lineData, to: projectCrashLogFileURL)
        } catch {
            return
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
