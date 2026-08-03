import Foundation

public enum DiagnosticsEvent: String, Codable, Sendable {
    case appInitStart
    case appInitEnd
    case dependencyContainerInitStart
    case dependencyContainerInitEnd
    case serviceInitStart
    case serviceInitEnd
    case mainThreadBlockStart
    case mainThreadBlockEnd
    case taskStart
    case taskEnd
    case actorCallStart
    case actorCallEnd
    case syncWaitStart
    case syncWaitEnd
    case fileEnumerationStart
    case fileEnumerationEnd
    case embeddingGenerationStart
    case embeddingGenerationEnd
    case databaseOperationStart
    case databaseOperationEnd
    case indexingStart
    case indexingEnd
    case uiRenderStart
    case uiRenderEnd
    case warning
    case error
}

public struct DiagnosticsRecord: Codable, Sendable {
    public let ts: String
    public let event: DiagnosticsEvent
    public let name: String
    public let durationMs: Double?
    public let threadId: Int
    public let isMainThread: Bool
    public let metadata: [String: String]?
    public let stackTrace: String?
}

public actor DiagnosticsLogger {
    public static let shared = DiagnosticsLogger()
    
    private var logFileURL: URL?
    private var sessionStart: Date = Date()
    private var pendingOperations: [String: Date] = [:]
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
    
    private init() {}
    
    public func setup(projectRoot: URL) {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let logsDir = ideDir.appendingPathComponent("logs", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let fileURL = logsDir.appendingPathComponent("diagnostics.ndjson")
            self.logFileURL = fileURL
            sessionStart = Date()
            
            let tid = Int(bitPattern: pthread_self())
            writeRecord(DiagnosticsRecord(
                ts: ISO8601DateFormatter().string(from: Date()),
                event: .appInitStart,
                name: "session",
                durationMs: nil,
                threadId: tid,
                isMainThread: Thread.isMainThread,
                metadata: ["sessionStart": ISO8601DateFormatter().string(from: sessionStart)],
                stackTrace: nil
            ))
            
        } catch {
        }
    }
    
    public func logEvent(
        _ event: DiagnosticsEvent,
        name: String,
        metadata: [String: String]? = nil,
        includeStackTrace: Bool = false
    ) {
        let tid = Int(bitPattern: pthread_self())
        let record = DiagnosticsRecord(
            ts: ISO8601DateFormatter().string(from: Date()),
            event: event,
            name: name,
            durationMs: nil,
            threadId: tid,
            isMainThread: Thread.isMainThread,
            metadata: metadata,
            stackTrace: includeStackTrace ? Thread.callStackSymbols.joined(separator: "\n") : nil
        )
        writeRecord(record)
        
        let threadInfo = Thread.isMainThread ? "MAIN" : "BG-\(tid)"
    }
    
    public func logStart(_ name: String, event: DiagnosticsEvent = .taskStart) {
        let key = "\(event.rawValue)_\(name)"
        pendingOperations[key] = Date()
        logEvent(event, name: name, metadata: ["phase": "start"])
    }
    
    public func logEnd(_ name: String, event: DiagnosticsEvent = .taskEnd) {
        let startEvent = event.rawValue.replacingOccurrences(of: "End", with: "Start")
        let key = "\(startEvent)_\(name)"
        let startTime = pendingOperations.removeValue(forKey: key)
        let duration = startTime.map { Date().timeIntervalSince($0) * 1000 }
        
        var meta = ["phase": "end"]
        if let d = duration {
            meta["durationMs"] = String(format: "%.2f", d)
        }
        logEvent(event, name: name, metadata: meta)
    }
    
    public func logWarning(_ message: String, metadata: [String: String]? = nil) {
        logEvent(.warning, name: message, metadata: metadata, includeStackTrace: true)
    }
    
    public func logError(_ message: String, metadata: [String: String]? = nil) {
        logEvent(.error, name: message, metadata: metadata, includeStackTrace: true)
    }
    
    public func logMainThreadBlock(_ operation: String) -> String {
        let id = UUID().uuidString
        logEvent(.mainThreadBlockStart, name: operation, metadata: ["blockId": id], includeStackTrace: true)
        return id
    }
    
    public func logMainThreadBlockEnd(_ id: String, operation: String) {
        logEvent(.mainThreadBlockEnd, name: operation, metadata: ["blockId": id])
    }
    
    private func writeRecord(_ record: DiagnosticsRecord) {
        guard let logFileURL = logFileURL else { return }
        
        do {
            let data = try encoder.encode(record)
            var line = Data()
            line.append(data)
            line.append(Data("\n".utf8))
            
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: logFileURL, options: [.atomic])
            }
        } catch {
        }
    }
    
    public func getLogPath() -> String {
        logFileURL?.path ?? "not configured"
    }
}

public func diagnoseMainThreadBlock<T>(_ operation: String, _ work: () throws -> T) rethrows -> T {
    let isMainThread = Thread.isMainThread
    if isMainThread {
        let id = UUID().uuidString
        Task { await DiagnosticsLogger.shared.logEvent(.mainThreadBlockStart, name: operation, metadata: ["blockId": id], includeStackTrace: true) }
        defer {
            Task { await DiagnosticsLogger.shared.logEvent(.mainThreadBlockEnd, name: operation, metadata: ["blockId": id]) }
        }
        return try work()
    } else {
        return try work()
    }
}

public func diagnoseAsyncOperation(_ name: String, event: DiagnosticsEvent = .taskStart) -> String {
    let id = "\(name)_\(UUID().uuidString)"
    Task { await DiagnosticsLogger.shared.logStart(id, event: event) }
    return id
}

public func diagnoseAsyncOperationEnd(_ id: String, event: DiagnosticsEvent = .taskEnd) {
    Task { await DiagnosticsLogger.shared.logEnd(id, event: event) }
}
