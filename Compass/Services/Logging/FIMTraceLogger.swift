import Foundation

/// Debug-only NDJSON tracer for the inline-completion pipeline.
///
/// Records keystrokes, gate decisions, pool/chain state, consumption, and
/// inference stats so typing behavior can be reviewed after the fact
/// (`.ide/logs/fim-trace.ndjson`). Enabled in DEBUG builds unless
/// `COMPASS_FIM_TRACE=0`. Cost per keystroke is one small JSON line — the
/// user explicitly requested this instrumentation for diagnosing suggestion
/// hit-rate/performance issues.
final class FIMTraceLogger: @unchecked Sendable {
    static let shared = FIMTraceLogger()

    private let lock = NSLock()
    private var handle: FileHandle?
    private let isEnabled: Bool
    private let encoder = JSONEncoder()
    private var projectRoot: URL?

    private init() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        isEnabled = env["COMPASS_FIM_TRACE"] != "0"
        #else
        isEnabled = false
        #endif
        if isEnabled {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            openLog(for: cwd)
        }
    }

    /// Point the trace at the project's `.ide/logs` directory (same wiring as
    /// AppLogger.setProjectRoot). Falls back to the current directory.
    func setProjectRoot(_ root: URL) {
        lock.lock(); defer { lock.unlock() }
        projectRoot = root
        guard isEnabled else { return }
        close()
        openLog(for: root)
    }

    private func openLog(for root: URL) {
        let ideDir = root.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let logsDir = ideDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("fim-trace.ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    func log(_ event: String, _ data: [String: String] = [:]) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        var payload: [String: String] = data
        payload["event"] = event
        payload["ts"] = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let json = try? encoder.encode(payload) else { return }
        handle.write(json)
        handle.write(Data("\n".utf8))
    }
}
