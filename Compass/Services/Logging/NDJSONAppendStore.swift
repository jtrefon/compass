import Foundation

/// Actor-isolated NDJSON append store.
///
/// **Design rationale:**
/// - Serializes all appends by construction (actor isolation) — concurrent
///   writers can no longer interleave bytes within a line or race the
///   fileExists→open TOCTOU that the previous enum-based writer had.
/// - One long-lived `FileHandle` per file: no existence checks, no open/close
///   churn on the hot path. A stale handle (file moved/deleted underneath us)
///   is evicted and reopened once before failing.
/// - Failures are LOUD: counted in `writeFailures` and logged via AppLogger.
///   These logs are the harness's validation source of truth — silent loss
///   breaks the "trace the telemetry" debugging contract.
/// - Per-write `synchronize()` (fsync): volume is low (per message / per tool
///   result) and crash-loss of audit trails is worse than the millisecond cost.
///
/// The single production append path for every NDJSON log file.
public actor NDJSONAppendStore {
    public static let shared = NDJSONAppendStore()

    private var handles: [URL: FileHandle] = [:]

    /// Total failed appends since process start. Surfaced for harness
    /// telemetry — a non-zero value means the run's logs are incomplete.
    public private(set) var writeFailures = 0

    public init() {}

    /// Appends one already-encoded NDJSON line (including its trailing
    /// newline) to the given file. Never throws — failures are logged and
    /// counted; logging must never break the caller's work.
    public func append(_ line: Data, to fileURL: URL) {
        do {
            let handle = try openHandle(for: fileURL)
            do {
                try write(line, via: handle)
            } catch {
                // Stale/closed handle under a moved or replaced file — evict,
                // reopen, retry exactly once before giving up.
                handles[fileURL] = nil
                try? handle.close()
                let fresh = try openHandle(for: fileURL)
                try write(line, via: fresh)
            }
        } catch {
            writeFailures += 1
            let failures = writeFailures
            Task {
                await AppLogger.shared.error(
                    category: .app,
                    message: "NDJSONAppendStore.append failed (\(failures) total): \(error.localizedDescription) — \(fileURL.path)"
                )
            }
        }
    }

    /// Flushes and closes all cached handles (called on teardown).
    public func closeAll() {
        for (_, handle) in handles {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
    }

    // MARK: - Internals

    private func write(_ line: Data, via handle: FileHandle) throws {
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    private func openHandle(for fileURL: URL) throws -> FileHandle {
        if let cached = handles[fileURL] { return cached }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let handle: FileHandle
        if let existing = try? FileHandle(forWritingTo: fileURL) {
            handle = existing
        } else {
            // First write to this file — create it atomically, then open.
            try Data().write(to: fileURL, options: .atomic)
            handle = try FileHandle(forWritingTo: fileURL)
        }
        handles[fileURL] = handle
        return handle
    }
}
