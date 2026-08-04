import Foundation

public actor UIRenderDiagnostics {
    public static let shared = UIRenderDiagnostics()
    
    private var logFileURL: URL?
    private var renderCounts: [String: Int] = [:]
    private var lastRenderTimes: [String: Date] = [:]
    private var rapidRenderWarnings: [String: Int] = [:]
    
    private init() {}
    
    public func setup(projectRoot: URL) {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let logsDir = ideDir.appendingPathComponent("logs", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let fileURL = logsDir.appendingPathComponent("ui-render.ndjson")
            self.logFileURL = fileURL
        } catch {
        }
    }
    
    public func trackRender(viewName: String) {
        let now = Date()
        let count = (renderCounts[viewName] ?? 0) + 1
        renderCounts[viewName] = count
        
        // Check for rapid re-renders (more than 10 in 1 second = potential loop)
        if let lastTime = lastRenderTimes[viewName], now.timeIntervalSince(lastTime) < 1.0 {
            rapidRenderWarnings[viewName] = (rapidRenderWarnings[viewName] ?? 0) + 1
            if let warnings = rapidRenderWarnings[viewName], warnings > 10 {
                logWarning(viewName: viewName, count: count)
            }
        }
        
        lastRenderTimes[viewName] = now
        
        // Log every 50 renders
        if count % 50 == 0 {
            logRender(viewName: viewName, count: count)
        }
    }
    
    public func trackStateChange(stateName: String, value: String) {
        logStateChange(stateName: stateName, value: value)
    }
    
    public func getStats() -> [(String, Int)] {
        renderCounts.sorted { $0.value > $1.value }
    }
    
    private func logRender(viewName: String, count: Int) {
        guard let logFileURL = logFileURL else { return }
        
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "type": "render",
            "view": viewName,
            "count": count
        ]
        
        writeRecord(record, to: logFileURL)
    }
    
    private func logWarning(viewName: String, count: Int) {
        guard let logFileURL = logFileURL else { return }
        
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "type": "warning",
            "view": viewName,
            "count": count,
            "message": "Potential render loop detected"
        ]
        
        writeRecord(record, to: logFileURL)
    }
    
    private func logStateChange(stateName: String, value: String) {
        guard let logFileURL = logFileURL else { return }
        
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "type": "stateChange",
            "state": stateName,
            "value": value
        ]
        
        writeRecord(record, to: logFileURL)
    }
    
    private func writeRecord(_ record: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: record)
            var line = Data()
            line.append(data)
            line.append(Data("\n".utf8))
            
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: [.atomic])
            }
        } catch {
        }
    }
}

/// Track a view render - call from body
public func trackViewRender(_ name: String) {
    Task { await UIRenderDiagnostics.shared.trackRender(viewName: name) }
}

/// Track state changes
public func trackStateChange(_ name: String, value: String) {
    Task { await UIRenderDiagnostics.shared.trackStateChange(stateName: name, value: value) }
}
