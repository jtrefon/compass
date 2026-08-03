import Foundation

public actor RAGTraceLogger {
    public static let shared = RAGTraceLogger()

    private let sessionId: String

    private var projectLogFileURL: URL?

    public init(sessionId: String = UUID().uuidString) {
        self.sessionId = sessionId
    }

    public func setProjectRoot(_ projectRoot: URL) {
        let logsDir = projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        self.projectLogFileURL = logsDir.appendingPathComponent("rag.ndjson")
    }

    public func log(type: String, data: [String: Any] = [:], file: String = #fileID, line: Int = #line) {
        do {
            guard let logFileURL = projectLogFileURL else { return }
            try ensureDirectoryExists(for: logFileURL)

            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let payload: [String: Any] = [
                "ts": f.string(from: Date()),
                "session": sessionId,
                "type": type,
                "file": file,
                "line": line,
                "data": data
            ]

            let json = try JSONSerialization.data(withJSONObject: payload, options: [])
            guard var line = String(data: json, encoding: .utf8) else { return }
            line.append("\n")

            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logFileURL, options: [.atomic])
            }
        } catch {
            // Silently skip logging errors to avoid impacting caller
        }
    }

    private func ensureDirectoryExists(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }
}
