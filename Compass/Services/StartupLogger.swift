//
//  StartupLogger.swift
//  Compass
//
//  Lightweight diagnostic logger for app startup. Disabled in release builds.
//

import Foundation

/// Writes startup diagnostics to a timestamped log file.
/// Automatically disabled when `#if DEBUG` is false.
enum StartupLogger {

    private static let queue = DispatchQueue(label: "Compass.startup-logger")

    #if DEBUG
    private final class LoggerState: @unchecked Sendable {
        private let lock = NSLock()
        private let logURL: URL
        private var isFirstWrite = true

        init() {
            let dir = FileManager.default.temporaryDirectory
            self.logURL = dir.appendingPathComponent("Compass-startup-\(ProcessInfo.processInfo.processIdentifier).log")
        }

        func writeLog(_ line: String) {
            lock.lock()
            defer { lock.unlock() }

            if isFirstWrite {
                isFirstWrite = false
                try? line.write(to: logURL, atomically: true, encoding: .utf8)
            } else {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line.data(using: .utf8)!)
                    try? handle.close()
                }
            }
        }
    }

    private static let state = LoggerState()
    #endif

    /// Log a startup diagnostic message with an optional elapsed time.
    static func log(_ message: String, elapsedMs: Int? = nil) {
        #if DEBUG
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let elapsed = elapsedMs.map { " (\($0)ms)" } ?? ""
            let line = "[\(ts)] \(message)\(elapsed)\n"

            state.writeLog(line)

            fflush(stdout)
        }
        #endif
    }
}
